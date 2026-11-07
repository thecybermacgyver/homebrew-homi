class Homi < Formula
  desc "Self-hosted family organizer (calendar, chequebook, shopping, meal planner)"
  homepage "https://github.com/thecybermacgyver/homi"
  url "https://github.com/thecybermacgyver/homi/archive/refs/tags/v1.5.7.tar.gz"
  sha256 "ab2add02c77678c345d7a9006bd5a6b41683a76d20e7d31475450f35b8bb0ee3"
  license "AGPL-3.0-only"

  depends_on "docker"
  depends_on "docker-compose"

  def install
    libexec.install Dir["*"], ".env.example"

    (bin/"homi").write <<~SH
      #!/bin/bash
      set -euo pipefail
      HOMI_HOME="${HOMI_HOME:-$HOME/.homi}"
      mkdir -p "$HOMI_HOME"
      [ -f "$HOMI_HOME/.env" ] || cp "#{libexec}/.env.example" "$HOMI_HOME/.env"
      cd "#{libexec}"
      exec docker compose --env-file "$HOMI_HOME/.env" -p homi "${@:-up}"
    SH
  end

  def caveats
    <<~EOS
      Edit ~/.homi/.env first: replace every secret placeholder
      (openssl rand -hex 32) and set the public HTTPS origin. Then run:
        homi up -d --build
      Web is on 127.0.0.1:3100, Core on 127.0.0.1:3101.
    EOS
  end

  test do
    assert_predicate libexec/"compose.yaml", :exist?
  end
end
