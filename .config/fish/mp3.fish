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
        command pkg install -y $missing; or return $status
        for dependency in $missing
            if not command -q $dependency
                echo "Dependency unavailable after installation: $dependency" >&2
                return 1
            end
        end
    end
    set -l out_dir /sdcard/0/music
    command mkdir -p "$out_dir"; or return $status
    set -l result 0
    for url in $argv
        command yt-dlp --ignore-config -x \
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
            -o "$out_dir/%(title)s.%(ext)s" \
            -- "$url"
        set -l code $status
        if test $code -ne 0
            set result $code
        end
    end
    return $result
end
