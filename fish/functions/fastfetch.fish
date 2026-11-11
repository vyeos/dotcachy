# fastfetch with the vyeos name beside the stats when the terminal is wide enough,
# above them when it isn't, and the small three-row name in a very narrow one.
function fastfetch --wraps fastfetch --description 'fastfetch, laid out for the terminal width'
    set -l cols $COLUMNS
    if test -z "$cols"
        set cols (tput cols 2>/dev/null; or echo 80)
    end
    if test $cols -ge 100
        command fastfetch $argv
    else if test $cols -ge 60
        command fastfetch --logo-position top --logo-padding-top 0 $argv
    else
        command fastfetch --logo ~/.config/fastfetch/vyeos.txt --logo-type file --logo-position top --logo-padding-top 0 $argv
    end
end
