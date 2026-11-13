function mp3 --description 'MP3'
    if test (count $argv) -eq 0
        echo 'Usage: mp3 URL [URL ...]' >&2
        return 2
    end
    for url in $argv
        if not string match -qr '^https?://[^[:space:]]+$' -- "$url"
            echo "Invalid URL: $url" >&2
            return 2
        end
    end
    set -l missing
    for dependency in yt-dlp ffmpeg
        if not command -q $dependency
            set -a missing $dependency
        end
    end
    if test (count $missing) -gt 0
        if not command -q pkg
            echo 'Termux package manager (pkg) not found.' >&2
            return 1
        end
        command bash -c 'set -uo pipefail
cyan=\'\' white=\'\' dim=\'\' reset=\'\'
select_mirror() {
    local probe_dir arch mirror i pid result best speed bytes
    local -a pids=() mirrors=(
        https://packages.termux.dev/apt/termux-main
        https://packages-cf.termux.dev/apt/termux-main
        https://grimler.se/termux/termux-main
        https://mirror.ufscar.br/termux/termux-main
    )

    command -v curl &>/dev/null || return 0
    arch=$(dpkg --print-architecture) || return 1
    probe_dir=$(mktemp -d) || return 1
    printf \'  %s◌%s Testing mirrors…%s\\n\' "$cyan" "$white" "$reset"

    for i in "${!mirrors[@]}"; do
        mirror=${mirrors[$i]}
        (
            result=$(LC_ALL=C curl --fail --silent --location \\
                --connect-timeout 3 --max-time 8 --range 0-262143 \\
                --output /dev/null --write-out \'%{speed_download} %{size_download}\' \\
                "$mirror/dists/stable/main/binary-$arch/Packages.xz") || exit 0
            read -r speed bytes <<< "$result"
            LC_ALL=C awk -v speed="$speed" -v bytes="$bytes" -v mirror="$mirror" \\
                \'BEGIN { if (speed > 0 && bytes >= 262144) print speed, mirror }\' > "$probe_dir/$i"
        ) &
        pids+=("$!")
    done

    for pid in "${pids[@]}"; do
        wait "$pid"
    done

    best=$(LC_ALL=C sort -k1,1nr "$probe_dir"/* 2>/dev/null | head -n 1)
    rm -rf "$probe_dir"
    if [ -z "$best" ]; then
        printf \'  %s↻ Keeping current mirror%s\\n\' "$dim" "$reset"
        return 0
    fi

    read -r speed mirror <<< "$best"
    if [ -f "$PREFIX/etc/apt/sources.list.d/main.sources" ]; then
        sed -i "s|^[[:space:]]*URIs:.*|URIs: $mirror|" "$PREFIX/etc/apt/sources.list.d/main.sources" || return 1
    else
        printf \'deb %s stable main\\n\' "$mirror" > "$PREFIX/etc/apt/sources.list" || return 1
    fi
    export TERMUX_PKG_NO_MIRROR_SELECT=true
    printf \'  %s✓%s %s%s\\n\' "$cyan" "$white" "$mirror" "$reset"
}
select_mirror || exit 1
pkg update -y || exit "$?"
pkg install -y "$@"
' -- $missing; or return $status
        for dependency in $missing
            if not command -q $dependency
                echo "Dependency unavailable after installation: $dependency" >&2
                return 1
            end
        end
    end
    set -l out_dir /sdcard/0/music
    command mkdir -p "$out_dir"; or return $status
    set -l log_dir "$HOME/.local/state/mp3/logs"
    command mkdir -p "$log_dir"; or return $status
    set -l live 0
    set -l status_width 79
    if isatty stdout
        set live 1
        if set -q COLUMNS; and string match -qr '^[0-9]+$' -- "$COLUMNS"
            set status_width (math "max(1, $COLUMNS - 1)")
        end
    end
    function __termux_mp3_status --no-scope-shadowing
        set -l text (string replace -ar '[[:cntrl:]]' ' ' -- "$argv[1]")
        if test $live -eq 1
            set -l color ''
            set -l reset ''
            if not set -q NO_COLOR; and test "$TERM" != dumb
                set color (set_color $argv[2])
                set reset (set_color normal)
            end
            printf '\r\033[K%s%s%s' "$color" (string shorten -m $status_width -- "$text") "$reset"
        else
            printf '%s\n' "$text"
        end
    end
    set -l result 0
    for url in $argv
        set -l title "$url"
        set -l failure ''
        set -l duration 0
        set -l phase preparing
        set -l log_file (command mktemp "$log_dir/download.XXXXXXXX.log")
        if test -z "$log_file"
            functions -e __termux_mp3_status
            return 1
        end
        printf '%s\n' "$url" > "$log_file"
        __termux_mp3_status "◌ Preparing · $title" yellow
        command bash -c 'log_dir=$1
shift
progress_dir=$(mktemp -d "$log_dir/progress.XXXXXXXX") || exit 1
progress="$progress_dir/ffmpeg"
stop="$progress_dir/stop"
watch_progress() {
    local current previous=\'\'
    while :; do
        if [ -s "$progress" ]; then
            current=$(awk -F= \'
                $1 == "out_time_us" { time=$2 }
                $1 == "speed" { speed=$2 }
                $1 == "progress" { print time "|" speed "|" $2 }
            \' "$progress" | tail -n 1)
            if [[ "$current" != "$previous" && "$current" =~ ^[0-9]+\\| ]]; then
                printf \'CONVERT:%s\\n\' "$current"
                previous=$current
            fi
        fi
        [ -e "$stop" ] && break
        sleep 0.25
    done
}
watch_progress &
watch_pid=$!
cleanup() {
    kill "$watch_pid" 2>/dev/null || true
    wait "$watch_pid" 2>/dev/null || true
    rm -f "$progress" "$stop"
    rmdir "$progress_dir"
}
trap cleanup EXIT
trap \'exit 130\' INT
trap \'exit 143\' TERM
printf -v progress_arg \'%q\' "$progress"
yt-dlp --postprocessor-args "ExtractAudio+ffmpeg_o:-progress $progress_arg -stats_period 0.25 -nostats" "$@"
code=$?
touch "$stop"
wait "$watch_pid"
exit "$code"
' -- "$log_dir" --ignore-config -x \
            --audio-format mp3 \
            --audio-quality 0 \
            -f 'ba/b' \
            --concurrent-fragments 5 \
            --no-playlist \
            --no-download-archive \
            --no-overwrites \
            --socket-timeout 15 \
            --retries 3 \
            --fragment-retries 3 \
            --embed-thumbnail \
            --add-metadata \
            --replace-in-metadata uploader ' - Topic$' '' \
            --parse-metadata 'uploader:%(artist)s' \
            --parse-metadata 'uploader:%(album_artist)s' \
            --replace-in-metadata title '(?i)\s*[\(\[]?\b(?:feat|ft)\b\.?\s*[\)\]]?.*$' '' \
            --no-simulate \
            --no-quiet \
            --newline \
            --progress \
            --progress-template 'download:PROG:%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s|%(info.title)s' \
            --print 'before_dl:TITLE:%(title)s' \
            --print 'before_dl:DURATION:%(duration)s' \
            --print 'after_move:DONE:%(title)s' \
            -o "$out_dir/%(title)s.%(ext)s" \
            -- "$url" 2>&1 | while read -l line
            printf '%s\n' "$line" >> "$log_file"
            if string match -q 'TITLE:*' -- "$line"
                set title (string sub -s 7 -- "$line")
                __termux_mp3_status "↓ Downloading · $title" cyan
            else if string match -q 'PROG:*' -- "$line"
                set -l parts (string split '|' -- (string sub -s 6 -- "$line"))
                if test (count $parts) -ge 4
                    set -l percent (string trim -- "$parts[1]")
                    set -l speed (string trim -- "$parts[2]")
                    set -l eta (string trim -- "$parts[3]")
                    set title (string join '|' -- $parts[4..-1])
                    set -l numeric (string replace -a '%' '' -- "$percent")
                    set -l bar '··········'
                    if string match -qr '^[0-9]+(\.[0-9]+)?$' -- "$numeric"
                        set -l filled (math "min(10, max(0, floor($numeric / 10)))")
                        set bar (string join '' -- (string repeat -n $filled '━') (string repeat -n (math "10 - $filled") '─'))
                    end
                    __termux_mp3_status "↓ $percent $bar · $speed · ETA $eta · $title" cyan
                end
            else if string match -q 'DURATION:*' -- "$line"
                set -l value (string sub -s 10 -- "$line")
                if string match -qr '^[0-9]+(\.[0-9]+)?$' -- "$value"
                    set duration "$value"
                end
            else if string match -q 'CONVERT:*' -- "$line"
                if test "$phase" != converting
                    continue
                end
                set -l parts (string split '|' -- (string sub -s 9 -- "$line"))
                if test (count $parts) -ne 3; or not string match -qr '^[0-9]+$' -- "$parts[1]"
                    continue
                end
                set -l seconds (math "$parts[1] / 1000000")
                set -l speed (string trim -- "$parts[2]")
                set -l detail (printf '%.0fs processed' "$seconds")
                if test "$speed" != N/A; and test -n "$speed"
                    set detail "$detail · $speed"
                end
                if test "$duration" -gt 0
                    set -l percent (math "min(99, max(0, floor($seconds / $duration * 100)))")
                    if test "$parts[3]" = end
                        set percent 100
                    end
                    set -l filled (math "floor($percent / 10)")
                    set -l bar (string join '' -- (string repeat -n $filled '━') (string repeat -n (math "10 - $filled") '─'))
                    set detail "$percent% $bar · $speed"
                    set -l rate (string replace -r 'x$' '' -- "$speed")
                    if string match -qr '^[0-9]+(\.[0-9]+)?$' -- "$rate"; and test "$rate" -gt 0
                        set -l eta (math "ceil(max(0, $duration - $seconds) / $rate)")
                        set detail "$detail · ETA "$eta"s"
                    end
                end
                __termux_mp3_status "♫ Converting $detail · $title" magenta
            else if string match -q 'DONE:*' -- "$line"
                set title (string sub -s 6 -- "$line")
            else if string match -q 'ERROR:*' -- "$line"
                set failure (string replace -r '^ERROR: *' '' -- "$line")
            else if string match -qr '^\[ExtractAudio\]' -- "$line"
                set phase converting
                __termux_mp3_status "♫ Converting to MP3 · $title" magenta
            else if string match -qr '^\[(EmbedThumbnail|ThumbnailsConvertor)\]' -- "$line"
                set phase cover
                __termux_mp3_status "◈ Adding cover · $title" magenta
            else if string match -qr '^\[Metadata\]' -- "$line"
                set phase metadata
                __termux_mp3_status "◇ Adding metadata · $title" magenta
            end
        end
        set -l code $pipestatus[1]
        if test $code -ne 0
            set result $code
            if test -z "$failure"
                set failure "Download failed (exit $code)"
            end
            __termux_mp3_status "✗ $failure" red
        else
            __termux_mp3_status "✓ $title" green
            command rm -f "$log_file"
        end
        if test $live -eq 1
            printf '\n'
        end
        if test $code -ne 0
            printf 'Log: %s\n' "$log_file" >&2
        end
    end
    functions -e __termux_mp3_status
    return $result
end
