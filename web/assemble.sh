# Sourced by build-bundle.sh and build-web-patch.sh, so that a bundle and a page
# update carry the page as the same files, laid out as install-web.sh and
# install-web.ps1 expect.

assemble_web() { # $1 = folder holding web/ and bundle/, $2 = folder to put the page in, $3 = the line for web/BUILD, $4 = mac, windows or mac,windows
  local src="$1" out="$2" targets="$4"
  mkdir -p "$out/web/static"
  cp "$src/web/app.py" "$src/web/check.py" "$src/web/extract.py" "$src/web/gemma.py" "$out/web/"
  # The page runs the dropped-text check that translate.sh carries, not a copy
  # kept by hand: take it out of the helper as calibration/measure.sh does.
  sed -n "/^cat > \"\$TMP\/check.pl\" <<'PERL'\$/,/^PERL\$/p" "$src/bundle/translate.sh" | sed '1d;$d' > "$out/web/check.pl"
  [ -s "$out/web/check.pl" ] && perl -c "$out/web/check.pl" 2>/dev/null \
    || die "couldn't take the dropped-text check out of bundle/translate.sh"
  cp "$src"/web/static/* "$out/web/static/"
  case ",$targets," in *,mac,*)
    cp "$src/bundle/install-web.sh" "$out/"
    chmod +x "$out/install-web.sh"
  esac
  case ",$targets," in *,windows,*)
    cp "$src/bundle/install-web.ps1" "$out/"
    # Command Prompt misreads batch files whose lines end the Unix way.
    perl -pe 's/\r?\n\z/\r\n/' "$src/bundle/install-web.cmd" > "$out/install-web.cmd"
  esac
  echo "$3" > "$out/web/BUILD"
}
