{
  lib,
  stdenv,
  fetchurl,
  gettext,
  makeWrapper,
  nodejs,
  python3,
  python3Packages,
  fetchYarnDeps,
  yarnConfigHook,

  # source trees, as fileset-derived store paths
  backendSrc,
  frontendSrc,

  # repository metadata
  inventreeVersion,
  commitHash,
  commitDate,

  # hashes (start with lib.fakeHash, then substitute the values reported
  # by failed builds)
  yarnDepsHash,
  fsmPypiHash,
}: let
  # Upstream pins django-fsm-2 (a maintained fork of django-fsm providing
  # the same "django_fsm" import); it is not in nixpkgs, so vendor it here.
  django-fsm-2 = python3Packages.buildPythonPackage rec {
    pname = "django-fsm-2";
    version = "4.2.4";
    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/fa/eb/594712952364f0b1f009b9c414940a09031d07fe95bb888e92f50aa9a550/django_fsm_2-4.2.4.tar.gz";
      hash = fsmPypiHash;
    };
    build-system = [python3Packages.hatchling];
    pyproject = true;
    dependencies = with python3Packages; [
      django
      django-stubs-ext
    ];
    # upstream ships no test suite in the sdist
    doCheck = false;
    pythonImportsCheck = ["django_fsm"];
  };

  pythonEnv = python3.withPackages (ps:
    lib.flatten (with ps; [
      django
      django-allauth
      django-anymail
      django-auditlog
      django-cleanup
      django-cors-headers
      django-dbbackup
      django-error-report-2
      django-filter
      django-flags
      django-fsm-2
      django-ical
      django-mailbox
      django-markdownify
      django-maintenance-mode
      django-money
      django-mptt
      django-oauth-toolkit
      django-otp
      django-q2
      django-redis
      django-sesame
      django-sql-utils
      django-sslserver
      django-stdimage
      django-storages
      django-structlog
      django-taggit
      django-xforwardedfor-middleware
      djangorestframework
      djangorestframework-simplejwt
      drf-spectacular
      scim2-models

      blessed
      cryptography
      docutils
      dulwich
      feedparser
      gunicorn
      jinja2
      lxml
      nh3
      pdf2image
      pillow
      pint
      ppf-datamatrix
      pypdf
      python-barcode
      python-dotenv
      pyyaml
      qrcode
      rapidfuzz
      sentry-sdk
      structlog
      tablib
      tqdm
      typing-extensions
      weasyprint
      whitenoise

      opentelemetry-api
      opentelemetry-sdk
      opentelemetry-exporter-otlp
      opentelemetry-instrumentation-django
      opentelemetry-instrumentation-requests
      opentelemetry-instrumentation-redis
      opentelemetry-instrumentation-sqlite3
      opentelemetry-instrumentation-system-metrics
      opentelemetry-instrumentation-wsgi
      opentelemetry-instrumentation-psycopg

      # optional-dependencies of the packages above, as required by
      # src/backend/requirements.in
      python-barcode.optional-dependencies.images
      qrcode.optional-dependencies.pil
      tablib.optional-dependencies.xls
      tablib.optional-dependencies.xlsx
      tablib.optional-dependencies.yaml
      djangorestframework-simplejwt.optional-dependencies.crypto
      django-anymail.optional-dependencies.amazon-ses
      django-anymail.optional-dependencies.postal
      django-storages.optional-dependencies.s3
      django-storages.optional-dependencies.sftp
      django-allauth.optional-dependencies.headless
      django-allauth.optional-dependencies.mfa
      django-allauth.optional-dependencies.openid
      django-allauth.optional-dependencies.saml
      django-allauth.optional-dependencies.socialaccount
    ]));

  frontend = stdenv.mkDerivation (finalAttrs: {
    pname = "inventree-frontend";
    version = inventreeVersion;
    src = frontendSrc;

    yarnOfflineCache = fetchYarnDeps {
      yarnLock = finalAttrs.src + "/yarn.lock";
      hash = yarnDepsHash;
    };

    nativeBuildInputs = [
      nodejs
      yarnConfigHook
      gettext
    ];

    postPatch = ''
      substituteInPlace vite.config.ts \
        --replace-fail "../../src/backend/InvenTree/web/static/web" "out/static/web"
    '';

    buildPhase = ''
      runHook preBuild

      export PATH="$PWD/node_modules/.bin:$PATH"
      export NODE_OPTIONS="--max-old-space-size=2048"
      yarn --offline run extract
      yarn --offline run compile
      yarn --offline run build

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out
      mv out/static $out/

      runHook postInstall
    '';
  });
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "inventree";
    version = inventreeVersion;
    src = backendSrc;

    nativeBuildInputs = [
      pythonEnv
      gettext
      makeWrapper
    ];

    dontConfigure = true;

    # Python unit tests are intentionally not run in this derivation;
    # upstream runs them separately in CI.
    doCheck = false;

    installPhase = ''
      runHook preInstall

      appDir=$out/lib/inventree/src/backend/InvenTree

      mkdir -p $out/lib/inventree
      cp -r src $out/lib/inventree

      # Compiled SPA output, at the path InvenTree's settings expect
      ln -s ${frontend}/static $appDir/web/static

      chmod +x $appDir/manage.py

      makeWrapper ${pythonEnv}/bin/python $out/bin/inventree \
        --add-flags "$appDir/manage.py" \
        --set INVENTREE_COMMIT_HASH ${commitHash} \
        --set INVENTREE_COMMIT_DATE ${commitDate}

      makeWrapper ${pythonEnv}/bin/gunicorn $out/bin/gunicorn \
        --prefix PYTHONPATH : "$appDir" \
        --set INVENTREE_COMMIT_HASH ${commitHash} \
        --set INVENTREE_COMMIT_DATE ${commitDate}

      # Generate static assets and compile translations
      pushd $appDir &>/dev/null
      export INVENTREE_STATIC_ROOT=$out/lib/inventree/static
      export INVENTREE_MEDIA_ROOT=$(mktemp -d)
      export INVENTREE_BACKUP_DIR=$(mktemp -d)
      export INVENTREE_DB_ENGINE=sqlite3
      export INVENTREE_DB_NAME=$(mktemp -u).db
      export INVENTREE_SITE_URL=http://localhost
      python ./manage.py collectstatic --no-input
      python ./manage.py compilemessages
      popd &>/dev/null

      # The SPA output is only in STATICFILES_DIRS in debug mode, so
      # collectstatic does not pick it up; install it directly instead
      cp -r ${frontend}/static/web $out/lib/inventree/static/

      runHook postInstall
    '';

    passthru = {
      pythonEnv = pythonEnv;
    };

    meta = {
      description = "Open Source Inventory Management System";
      homepage = "https://inventree.org/";
      license = lib.licenses.mit;
      platforms = lib.platforms.linux;
      mainProgram = "inventree";
    };
  })
