# fastfetch with the pixel V beside the framed stats when the terminal has room
# (about 72 columns), and above them in a narrower one.
function fastfetch --wraps fastfetch --description 'fastfetch, laid out for the terminal width'
    set -l cols $COLUMNS
    if test -z "$cols"
        set cols (tput cols 2>/dev/null; or echo 80)
    end
    if test $cols -ge 72
        command fastfetch $argv
    else
        command fastfetch --logo-position top --logo-padding-top 0 --logo-padding-right 0 $argv
    end
end
