class Homi < Formula
  desc "Self-hosted family organizer (calendar, chequebook, shopping, meal planner)"
  homepage "https://github.com/thecybermacgyver/homi"
  url "https://github.com/thecybermacgyver/homi/archive/refs/tags/v1.5.7.tar.gz"
  sha256 "ab2add02c77678c345d7a9006bd5a6b41683a76d20e7d31475450f35b8bb0ee3"
  license "AGPL-3.0-only"

  depends_on "docker"
  depends_on "docker-compose"
  depends_on "openssl@3"

  def install
    libexec.install Dir["*"], ".env.example"

    (bin/"homi").write <<~'SH'
      #!/bin/bash
      # Homi launcher installed by Homebrew. Source lives in @LIBEXEC@;
      # your configuration and data live outside it (HOMI_HOME, default ~/.homi).
      set -euo pipefail

      HOMI_SRC="@LIBEXEC@"
      HOMI_HOME="${HOMI_HOME:-$HOME/.homi}"
      HOMI_PROJECT="${HOMI_PROJECT:-homi}"
      ENV_FILE="$HOMI_HOME/.env"

      die() { echo "homi: $*" >&2; exit 1; }
      say() { printf '\n==> %s\n' "$*"; }

      need_docker() {
        command -v docker >/dev/null 2>&1 || die "docker not found. Install Docker Desktop (or Colima) and start it."
        docker info >/dev/null 2>&1 || die "the Docker daemon is not running. Start Docker and try again."
        docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required (brew install docker-compose)."
      }

      need_env() {
        [ -f "$ENV_FILE" ] || die "no configuration found. Run 'homi init' first."
      }

      dc() { (cd "$HOMI_SRC" && docker compose --env-file "$ENV_FILE" -p "$HOMI_PROJECT" "$@"); }

      env_value() { grep -E "^$1=" "$ENV_FILE" | head -n1 | cut -d= -f2-; }

      ask() { # ask VAR "Prompt" "default"
        local var="$1" prompt="$2" def="${3:-}" val="${!1:-}"
        if [ -z "$val" ]; then
          read -r -p "$prompt${def:+ [$def]}: " val || true
        fi
        printf -v "$var" '%s' "${val:-$def}"
      }

      cmd_init() {
        [ -e "$ENV_FILE" ] && die "$ENV_FILE already exists. Edit it, or delete it to start over."
        command -v openssl >/dev/null 2>&1 || die "openssl is required to generate secrets."
        local url="${HOMI_AUTH_BASE_URL:-}"
        if [ -z "$url" ]; then
          read -r -p "Public URL for Homi [http://localhost:3100]: " url || true
        fi
        url="${url:-http://localhost:3100}"
        url="${url%/}"
        mkdir -p "$HOMI_HOME"
        chmod 700 "$HOMI_HOME"
        (
          umask 077
          while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
              *=replace-with-random-secret) printf '%s=%s\n' "${line%%=*}" "$(openssl rand -hex 32)" ;;
              HOMI_AUTH_BASE_URL=*) printf 'HOMI_AUTH_BASE_URL=%s\n' "$url" ;;
              *) printf '%s\n' "$line" ;;
            esac
          done < "$HOMI_SRC/.env.example" > "$ENV_FILE"
        )
        say "Wrote $ENV_FILE with freshly generated secrets."
        echo "Back this file up. Without it you cannot reach your data."
        echo "Next: homi setup"
      }

      cmd_setup() {
        need_env
        need_docker
        [ -e "$HOMI_HOME/.setup-complete" ] && die "setup already completed. Use 'homi start' or 'homi update'."

        local tz_guess lc_guess
        tz_guess="$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' || true)"
        lc_guess="$(printf '%s' "${LANG:-}" | sed -E 's/^([a-z]{2,3})_([A-Z]{2}).*/\1-\2/' )"
        case "$lc_guess" in [a-z][a-z]-[A-Z][A-Z]) ;; *) lc_guess="en-US" ;; esac

        if [ ! -e "$HOMI_HOME/.bootstrapped" ]; then
          say "Create the first account (the Household Administrator)"
          ask HOMI_BOOTSTRAP_NAME "Your name" ""
          ask HOMI_BOOTSTRAP_EMAIL "Your email (used to sign in)" ""
          ask HOMI_BOOTSTRAP_HOUSEHOLD "Household name" "Our Home"
          ask HOMI_BOOTSTRAP_LOCALE "Locale" "$lc_guess"
          ask HOMI_BOOTSTRAP_TIME_ZONE "Time zone" "${tz_guess:-UTC}"
          if [ -z "${HOMI_BOOTSTRAP_PASSWORD:-}" ]; then
            local pw2
            read -r -s -p "Choose a password: " HOMI_BOOTSTRAP_PASSWORD || true; echo
            read -r -s -p "Repeat password: " pw2 || true; echo
            [ "$HOMI_BOOTSTRAP_PASSWORD" = "$pw2" ] || die "passwords did not match."
          fi
          [ -n "$HOMI_BOOTSTRAP_NAME" ] && [ -n "$HOMI_BOOTSTRAP_EMAIL" ] && [ -n "$HOMI_BOOTSTRAP_PASSWORD" ] \
            || die "name, email and password are required."
          export HOMI_BOOTSTRAP_NAME HOMI_BOOTSTRAP_EMAIL HOMI_BOOTSTRAP_HOUSEHOLD \
                 HOMI_BOOTSTRAP_LOCALE HOMI_BOOTSTRAP_TIME_ZONE HOMI_BOOTSTRAP_PASSWORD
        fi

        say "Building images (the first build takes several minutes)"
        dc build

        say "Starting the database"
        dc up -d --wait db

        say "Running database migrations"
        dc --profile maintenance run --rm -T migrate

        if [ ! -e "$HOMI_HOME/.bootstrapped" ]; then
          say "Creating the first account and household"
          dc --profile maintenance run --rm -T \
            -e HOMI_BOOTSTRAP_EMAIL -e HOMI_BOOTSTRAP_PASSWORD -e HOMI_BOOTSTRAP_NAME \
            -e HOMI_BOOTSTRAP_HOUSEHOLD -e HOMI_BOOTSTRAP_LOCALE -e HOMI_BOOTSTRAP_TIME_ZONE \
            bootstrap
          unset HOMI_BOOTSTRAP_PASSWORD
          touch "$HOMI_HOME/.bootstrapped"
        fi

        say "Installing the Calendar and Chequebook modules"
        dc --profile maintenance run --rm -T module-admin install /app/packages/calendar
        dc --profile maintenance run --rm -T module-admin install /app/packages/chequebook

        say "Starting Homi"
        dc up -d --wait module-manager core web
        touch "$HOMI_HOME/.setup-complete"

        say "Homi is running."
        echo "Open: $(env_value HOMI_AUTH_BASE_URL)"
        echo "Sign in as $HOMI_BOOTSTRAP_EMAIL, then enable modules under Modules in the app."
        echo "Serving over the internet? Put an HTTPS reverse proxy in front of ports $(env_value HOMI_WEB_PORT)/$(env_value HOMI_CORE_PORT)."
      }

      cmd_update() {
        need_env
        need_docker
        say "Rebuilding images from the installed Homi version"
        dc build
        dc up -d --wait db
        dc --profile maintenance run --rm -T migrate
        dc --profile maintenance run --rm -T module-admin install /app/packages/calendar
        dc --profile maintenance run --rm -T module-admin install /app/packages/chequebook
        dc up -d --wait module-manager core web
        say "Homi is up to date."
      }

      cmd_help() {
        cat <<'HELP'
      Usage: homi <command>

        init      Generate ~/.homi/.env with fresh secrets
        setup     Build, migrate, create the first account, install modules, start
        start     Start Homi
        stop      Stop Homi (data is kept)
        update    After 'brew upgrade homi': rebuild, migrate and restart
        status    Show running services
        logs      Follow service logs (homi logs core)
        compose   Pass-through to docker compose, e.g. homi compose ps

      Environment: HOMI_HOME (default ~/.homi), HOMI_PROJECT (default homi)
      HELP
      }

      case "${1:-help}" in
        init)    cmd_init ;;
        setup)   cmd_setup ;;
        update)  cmd_update ;;
        start)   need_env; need_docker; dc up -d --wait ;;
        stop)    need_env; need_docker; dc stop ;;
        status)  need_env; need_docker; dc ps ;;
        logs)    shift; need_env; need_docker; dc logs -f --tail=100 "$@" ;;
        compose) shift; need_env; need_docker; dc "$@" ;;
        help|-h|--help) cmd_help ;;
        *) cmd_help; exit 1 ;;
      esac
    SH
    inreplace bin/"homi", "@LIBEXEC@", libexec.to_s
    chmod 0555, bin/"homi"
  end

  def caveats
    <<~EOS
      Homi runs in Docker. Start Docker, then:
        homi init     # generate secrets in ~/.homi/.env
        homi setup    # build, migrate, create your account, install modules, start
    EOS
  end

  test do
    assert_match "Usage: homi", shell_output("#{bin}/homi help")
    assert_predicate libexec/"compose.yaml", :exist?
    assert_predicate libexec/".env.example", :exist?
  end
end
