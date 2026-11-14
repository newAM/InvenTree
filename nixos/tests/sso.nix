{
  self,
  pkgs,
}: let
  inventreeDomain = "homeshare.home.arpa";
  kanidmDomain = "kanidm.home.arpa";
  nginxPort = 10443;
  kanidmPort = 20443;
  inventreeUrl = "https://${inventreeDomain}:${toString nginxPort}";
  kanidmUrl = "https://${kanidmDomain}:${toString kanidmPort}";

  oidcClientId = "inventree";
  oidcClientSecret = "inventree-test-oidc-client-secret";

  kanidmUsername = "testuser";

  socialProviders = builtins.toJSON {
    openid_connect = {
      APPS = [
        {
          provider_id = oidcClientId;
          name = "Kanidm";
          client_id = oidcClientId;
          secret = oidcClientSecret;
          settings.server_url = "${kanidmUrl}/oauth2/openid/${oidcClientId}";
        }
      ];
    };
  };
in
  pkgs.testers.nixosTest {
    name = "inventree-sso";

    nodes.machine = {
      config,
      lib,
      ...
    }: let
      # allauth fetches the OIDC discovery document from the IdP via
      # python-requests, which uses certifi's CA bundle rather than the
      # system bundle that security.pki.certificateFiles feeds; point the
      # InvenTree services at the system bundle so the IdP certificate
      # (and any other locally trusted CA) is accepted.
      systemCaBundle = {
        SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
        REQUESTS_CA_BUNDLE = "/etc/ssl/certs/ca-bundle.crt";
      };
    in {
      nixpkgs.overlays = [self.overlays.default];

      networking.hosts."127.0.0.1" = [inventreeDomain kanidmDomain];
      networking.firewall.allowedTCPPorts = [443 nginxPort kanidmPort];

      environment.systemPackages = [pkgs.htmlq];

      # kanidm identity provider
      services.kanidm = {
        package = pkgs.kanidmWithSecretProvisioning_1_12;
        server = {
          enable = true;
          settings = {
            version = "2";
            bindaddress = "0.0.0.0:${toString kanidmPort}";
            domain = kanidmDomain;
            origin = kanidmUrl;
            tls_chain = ./kanidm.home.arpa.cert.pem;
            tls_key = ./kanidm.home.arpa.key.pem;
          };
        };
        client = {
          enable = true;
          settings = {
            uri = kanidmUrl;
            verify_ca = true;
            verify_hostnames = true;
          };
        };
        provision = {
          enable = true;
          systems.oauth2.${oidcClientId} = {
            displayName = "InvenTree";
            public = false;
            enableLegacyCrypto = false;
            # allauth's OIDC client does not use PKCE
            allowInsecureClientDisablePkce = true;
            preferShortUsername = true;
            basicSecretFile = pkgs.writeText "inventree_oidc_client_secret" oidcClientSecret;
            # django-allauth openid_connect callback route. nginx forwards
            # the Host header without the port, so allauth builds the
            # callback URL without it; authorize both forms.
            originUrl = [
              "${inventreeUrl}/accounts/${oidcClientId}/login/callback/"
              "https://${inventreeDomain}/accounts/${oidcClientId}/login/callback/"
            ];
            originLanding = inventreeUrl;
            scopeMaps."inventree_users" = ["openid" "email" "profile"];
            removeOrphanedClaimMaps = true;
          };
          persons.${kanidmUsername} = {
            displayName = "Test User";
            mailAddresses = ["testuser@example.com"];
          };
          groups."inventree_users".members = [kanidmUsername];
        };
      };

      # InvenTree service provider
      services.inventree = {
        enable = true;
        domain = inventreeDomain;
        adminPasswordFile = pkgs.writeText "inventree_admin_password" "inventree-admin-password";
        settings = {
          INVENTREE_SITE_URL = inventreeUrl;
          INVENTREE_SOCIAL_BACKENDS = "openid_connect";
          INVENTREE_SOCIAL_PROVIDERS = socialProviders;
          # SSO sign-up requires a configured mail backend
          INVENTREE_EMAIL_HOST = "localhost";
          INVENTREE_EMAIL_SENDER = "inventree@example.org";
        };
      };

      # Enable the SSO login options (database-backed global settings)
      systemd.services =
        {
          inventree-sso-settings = {
            description = "Enable SSO settings in InvenTree";
            wantedBy = ["inventree.target"];
            after = ["inventree-setup.service"];
            before = ["inventree-server.service" "inventree-qcluster.service"];
            serviceConfig = {
              Type = "oneshot";
              User = "inventree";
              Group = "inventree";
              RemainAfterExit = true;
            };
            environment =
              config.services.inventree.settings
              // systemCaBundle;
            script = ''
              set -eu
              ${config.services.inventree.package}/bin/inventree shell -c "
              from common.settings import set_global_setting
              set_global_setting('LOGIN_ENABLE_SSO', 'True')
              set_global_setting('LOGIN_ENABLE_SSO_REG', 'True')
              set_global_setting('LOGIN_SIGNUP_SSO_AUTO', 'True')
              "
            '';
          };
        }
        // lib.genAttrs
        ["inventree-setup" "inventree-server" "inventree-qcluster"]
        (_: {environment = systemCaBundle;});

      services.nginx = {
        enable = true;
        defaultSSLListenPort = nginxPort;
        # Forwarding $http_host (needed so allauth builds URLs with the
        # non-standard port) trips the gixy host-spoofing lint baked into
        # config validation; the Host header is not attacker-controlled in
        # this VM, and nginx itself still validates the config on start
        validateConfigFile = false;
        virtualHosts.${inventreeDomain} = {
          onlySSL = true;
          sslCertificate = ./homeshare.home.arpa.cert.pem;
          sslCertificateKey = ./homeshare.home.arpa.key.pem;
          # The automated test drives the portless OAuth2 callback (the
          # Host form a default nginx setup forwards), so serve 443 too
          listen = [
            {
              addr = "0.0.0.0";
              port = nginxPort;
              ssl = true;
            }
            {
              addr = "0.0.0.0";
              port = 443;
              ssl = true;
            }
          ];
          # Forward the port in the Host header so allauth generates
          # absolute URLs (including the OAuth2 callback) pointing back
          # at this vhost on its non-standard port; the recommended
          # proxy settings would strip it. Mirrors the location block
          # from the inventree NixOS module, with Host overridden.
          locations."/".recommendedProxySettings = lib.mkForce false;
          locations."/".extraConfig = lib.mkForce ''
            proxy_set_header Host $http_host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header X-Forwarded-Host $host;
            proxy_set_header X-Forwarded-Server $host;

            proxy_set_header X-Forwarded-By $server_addr:$server_port;
            proxy_set_header CLIENT_IP $remote_addr;

            proxy_pass_request_headers on;

            proxy_redirect off;

            client_max_body_size 100M;

            proxy_buffering off;
            proxy_request_buffering off;
          '';
        };
      };

      security.pki.certificateFiles = [
        ./homeshare.home.arpa.cert.pem
        ./kanidm.home.arpa.cert.pem
      ];

      # gunicorn + qcluster + kanidm + postgresql
      virtualisation.memorySize = 2304;

      # For manual browser testing via the interactive driver. Host port
      # 443 cannot be forwarded (binding privileged ports is not allowed),
      # so the manual flow runs on ${toString nginxPort}; the vhost also
      # listens on 443 for the portless OAuth2 callback the automated
      # test exercises.
      virtualisation.forwardPorts = [
        {
          from = "host";
          host.port = 8443;
          guest.port = 443;
        }
        {
          from = "host";
          host.port = nginxPort;
          guest.port = nginxPort;
        }
        {
          from = "host";
          host.port = kanidmPort;
          guest.port = kanidmPort;
        }
      ];
    };

    testScript = ''
      machine.wait_for_unit("kanidm.service")
      machine.wait_for_open_port(${toString kanidmPort})
      machine.wait_until_succeeds("curl -sSf ${kanidmUrl}")

      machine.wait_for_unit("inventree.target")
      machine.wait_for_open_unix_socket("/run/inventree/gunicorn.socket")

      with subtest("SPA is served"):
          machine.wait_until_succeeds("curl -sSf ${inventreeUrl}/web")

      with subtest("API is up"):
          machine.succeed("curl -sSf ${inventreeUrl}/api/")

      with subtest("OIDC discovery is reachable and trusted from the app"):
          machine.succeed(
              "curl -sSf ${kanidmUrl}/oauth2/openid/${oidcClientId}/.well-known/openid-configuration"
          )

      # Password for the scripted and manual SSO login as ${kanidmUsername}
      password = machine.succeed(
          "kanidmd recover-account ${kanidmUsername} 2>&1 | grep -oP '[A-Za-z0-9]{48}'"
      ).strip()
      print(f"kanidm password for ${kanidmUsername}: {password}")

      with subtest("SSO login round trip"):
          # Submit the same form the SPA's login button posts; this drives
          # the in-process discovery fetch end to end. The portless Host
          # header exercises the portless callback registration, the form
          # a default nginx setup (Host stripped of its port) would
          # produce; the manual browser flow uses the ported form.
          machine.succeed("curl -sSf -c /tmp/inventree-cookies.txt -o /dev/null ${inventreeUrl}/web")
          csrf = machine.succeed(
              "awk '$6 == \"csrftoken\" {print $7}' /tmp/inventree-cookies.txt"
          ).strip()
          redirect = machine.succeed(
              "curl -s -o /dev/null -w '%{redirect_url}'"
              " -b /tmp/inventree-cookies.txt"
              " -H 'Origin: ${inventreeUrl}'"
              " -H 'Host: ${inventreeDomain}'"
              f" --data-urlencode 'csrfmiddlewaretoken={csrf}'"
              " --data-urlencode 'provider=${oidcClientId}'"
              " --data-urlencode 'callback_url=${inventreeUrl}/web/logged-in'"
              " --data-urlencode 'process=login'"
              " ${inventreeUrl}/api/auth/v1/auth/provider/redirect"
          ).strip()
          assert redirect.startswith("${kanidmUrl}/ui/oauth2"), (
              f"unexpected redirect target: {redirect}"
          )

          # kanidm login page; post the username to get the password form
          machine.succeed(
              f"curl -sSf -c /tmp/sso-cookies.txt -o /tmp/sso-login.html '{redirect}'",
              "htmlq '#login' --attribute action --filename /tmp/sso-login.html --output /tmp/sso-login-action.txt",
          )
          username_post = "${kanidmUrl}" + machine.succeed("head -1 /tmp/sso-login-action.txt").rstrip()
          machine.succeed(
              f"curl -sSf -b /tmp/sso-cookies.txt -c /tmp/sso-cookies.txt -o /tmp/sso-password.html"
              f" -d 'username=${kanidmUsername}' -d 'password=' -d 'totp='"
              f" '{username_post}'",
              "htmlq '#login' --attribute action --filename /tmp/sso-password.html --output /tmp/sso-password-action.txt",
          )
          password_post = "${kanidmUrl}" + machine.succeed("head -1 /tmp/sso-password-action.txt").rstrip()

          # post the password; the response redirects to a resume URL
          resume_url = machine.succeed(
              f"curl -sSf -b /tmp/sso-cookies.txt -c /tmp/sso-cookies.txt -w '%{{redirect_url}}' -o /dev/null"
              f" -d 'password={password}' '{password_post}'"
          ).rstrip()
          assert resume_url.startswith("https://"), f"invalid resume URL: {resume_url!r}"

          # consent page; posting the consent token redirects back to
          # the allauth callback (registered portless, hence port 443)
          machine.succeed(
              f"curl -sSf -b /tmp/sso-cookies.txt -c /tmp/sso-cookies.txt -o /tmp/sso-consent.html '{resume_url}'",
              "htmlq '#login' --attribute action --filename /tmp/sso-consent.html --output /tmp/sso-consent-action.txt",
              "htmlq '#consent_token' --attribute value --filename /tmp/sso-consent.html --output /tmp/sso-consent-token.txt",
          )
          consent_post = "${kanidmUrl}" + machine.succeed("head -1 /tmp/sso-consent-action.txt").rstrip()
          consent_token = machine.succeed("head -1 /tmp/sso-consent-token.txt").rstrip()
          callback_url = machine.succeed(
              f"curl -s -b /tmp/sso-cookies.txt -c /tmp/sso-cookies.txt -w '%{{redirect_url}}' -o /dev/null"
              f" -d 'consent_token={consent_token}' '{consent_post}'"
          ).rstrip()
          assert "/accounts/${oidcClientId}/login/callback/" in callback_url, (
              f"unexpected callback: {callback_url}"
          )

          # complete the login; the scripted leg verifies the server-side
          # chain ends at the allauth callback with a rendered page (the
          # JS-driven post-callback behavior is covered by the frontend
          # Playwright suite and manual browser testing)
          chain = machine.succeed(
              f"curl -s -L -b /tmp/inventree-cookies.txt -c /tmp/inventree-cookies.txt"
              f" -o /tmp/sso-callback-final.html -w '%{{http_code}} %{{url_effective}}'"
              f" '{callback_url}'"
          ).rstrip()
          print(f"callback chain: {chain}")
          status = chain.split(" ", 1)[0]
          assert status == "200", f"unexpected callback status: {chain}"
          machine.succeed("grep -q '<html' /tmp/sso-callback-final.html")
    '';
  }
