# Graphite prompt: directory, git branch (with * when dirty), then a chevron
# that turns muted red after a failed command. Monochrome, single line.
function fish_prompt
    set -l last_status $status

    set_color d3d6d9
    echo -n (prompt_pwd --full-length-dirs 2)

    set -l git (fish_git_prompt '%s')
    if test -n "$git"
        set_color 4b4f54
        echo -n '  '
        set_color 7a7f86
        echo -n $git
    end

    if test $last_status -ne 0
        set_color c9a3a0
    else
        set_color ededeb
    end
    echo -n ' › '
    set_color normal
end
