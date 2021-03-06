declare-option -docstring %{ Path to wiki directory } str wiki_path

# program that outputs relative path given two absolute as params
declare-option -hidden str wiki_relative_path_program %{ perl -e 'use File::Spec; print File::Spec->abs2rel(@ARGV) . "\n"' }
declare-option -hidden str wiki_tmp_dir
declare-option -hidden completions wiki_completions

define-command -hidden -params 1 wiki_setup %{
    %sh{
        echo "set-option global wiki_path $1"
        echo "hook global BufCreate $1/.+\.md %{ wiki_enable }"
    }
}

define-command wiki -params 1  \
-docstring %{ wiki [file.md]: Edit or create wiki page } \
-shell-candidates %{ cd $kak_opt_wiki_path; find . -type f -name '*.md' | sed -e 's/^\.\///y' }  \
%{ evaluate-commands %{ %sh{
    dir="$(dirname $1)"
    base="$(basename $1 .md)" #no extension
    normalized="$base.md"
    path="$dir/$normalized"
    if [ ! -e "$kak_opt_wiki_path/$path" ]; then
        echo "wiki_new_page \"$dir/$base\""
    fi
    echo edit \"$kak_opt_wiki_path/$path\"
}}}
# @+fd
define-command wiki_enable %{
    add-highlighter buffer group wiki
    add-highlighter buffer/wiki regex '\B@(\+|!)\S+' 0:link
    add-highlighter buffer/wiki regex '\[\w+\]' 0:link
    hook buffer InsertChar \n -group wiki %{
        evaluate-commands %{ try %{ 
            execute-keys -draft %{
                2h<a-b><a-k>\A@\+\w+<ret>
                :wiki_expand_tag<ret>
            }
            execute-keys <esc>h;di
        } }
    }
    hook buffer InsertChar \n -group wiki %{
        evaluate-commands %{ try %{ 
            execute-keys -draft %{
                2h<a-b><a-k>\A@!\w+<ret>
                :wiki_expand_pic<ret>
            }
            execute-keys <esc>h;di
        } }
    } 
    hook buffer NormalKey <ret> -group wiki %{
        wiki_follow_link
        wiki_toggle_checkbox
    }
    set-option -add buffer completers option=wiki_completions
    hook buffer -group wiki InsertIdle .* %{ try %{
        execute-keys -draft <a-h><a-k>\B(@(\+|!)).\z<ret>
        echo 'completing ...'
        wiki-complete
    } } 
    alias global complete wiki-complete 
}

define-command wiki_disable %{
    remove-highlighter buffer/wiki
    remove-hooks buffer wiki
}

define-command wiki_expand_tag \
-docstring %{ Expands tag from @+filename form to [filename](filename.md)
Creates empty markdown file in wiki_path if not exist. Selection must be
somewhere on @tag and @tag should not contain extension } %{
    evaluate-commands %{ %sh{
        this="$kak_buffile"
        tag=$(echo $kak_selection | sed -e 's/^\@+//')
        other="$kak_opt_wiki_path/$tag.md"
        relative=$(eval "$kak_opt_wiki_relative_path_program" "$other" $(dirname "$this"))
        # sanity check
        echo execute-keys -draft '<a-k>^@\+[^@+]+'
        echo execute-keys "c[$tag]($relative)<esc>"
        echo wiki_new_page "$tag"
    }}
}

define-command wiki_expand_pic \
-docstring %{ Expands images from @!filename.png form to ![filename.png](filename.png)} %{
    evaluate-commands %{ %sh{
        this="$kak_buffile"
        tag=$(echo $kak_selection | sed -e 's/^\@!//')
        other="$kak_opt_wiki_path/$tag"
        relative=$(eval "$kak_opt_wiki_relative_path_program" "$other" $(dirname "$this"))
        # sanity check
        echo execute-keys -draft '<a-k>^@\+[^@!]+'
        echo execute-keys "c![$tag]($relative)<esc>"
    }}
}

define-command -params 1 -hidden \
-docstring %{ wiki_new_page [name]: create new wiki page in wiki_path if not exists } \
wiki_new_page %{
    %sh{
        dir="$(dirname $kak_opt_wiki_path/$1.md)"
        mkdir -p "$dir"
        touch "$kak_opt_wiki_path/$1.md"
    }
}

define-command wiki_follow_link \
-docstring %{ Follow markdown link and open file if exists } %{
    evaluate-commands %{ try %{
        execute-keys %{
            <esc><a-a>c\[,\)<ret><a-:>
            <a-i>b
        }
        evaluate-commands -try-client %opt{jumpclient} edit -existing %sh{ echo $kak_selection }
        focus %opt{jumpclient}
    }}
}

define-command wiki_toggle_checkbox \
-docstring "Toggle markdown checkbox in current line" %{
    try %{
        try %{
            execute-keys -draft %{
                <esc><space>;xs-\s\[\s\]<ret><a-i>[rX
        }} catch %{
            execute-keys -draft %{
                <esc><space>;xs-\s\[X\]<ret><a-i>[r<space>
    }}}
}


define-command wiki-complete -docstring "Complete the current selection with files from wiki" %{
    evaluate-commands %sh{
        # ask Kakoune to write current buffer to temporary file
        dir=$(mktemp -d "${TMPDIR:-/tmp}/kak-wiki.XXXXXXXX")
        printf %s\\n "set-option buffer wiki_tmp_dir ${dir}"
        printf %s\\n "evaluate-commands -no-hooks %{ write ${dir}/buf }"
    }
    # End the %sh{} so that it's output gets executed by Kakoune.
    # Use a nop so that any eventual output of this %sh does not get interpreted.
    evaluate_commands %sh{
      dir=${kak_opt_wiki_tmp_dir}
      (
        buffer="${dir}/buf"
        line="${kak_cursor_line}"
        column="${kak_cursor_column}"
        tag=$(cut -c -$column "$buffer" | sed -n -E "$line"'s/^.*@(\+|!)([^@+]+)/\1/p;')
        # if [ "x$tag" != "x" ]; then
            candidates=$(cd "${kak_opt_wiki_path}"; find . -type f -name "$tag*.md" | sed -e 's/^\.\///g' -e 's/^\(\(.\+\)\.md\)$/\2||\1/g' -e 's/^\(\(.\+\)\.\)$/\1||\1/g' | tr '\n' ':' )
            candidates_nonmd=$(cd "${kak_opt_wiki_path}"; find . -type f -name "$tag*" -and -not -name '*.md' | sed -e 's/^\.\///g' -e 's/^\(.\+\)$/\1||\1/g' | tr '\n' ':' )
            # generate completion option value
            compl="$line.$column@$kak_timestamp:$candidates$candidates_nonmd"
            # write to Kakoune socket for the buffer that triggered the completion
            printf %s\\n "evaluate-commands -client '${kak_client}' %{
                    set-option buffer=${kak_bufname} wiki_completions %~${compl%?}~
                }" | tee "${dir}/cmd" 
            cat "${dir}/cmd" | kak -p ${kak_session}
            
        # fi
        rm -r "$dir"
    ) > /tmp/wiki_completer_log 2>&1 < /dev/null & }
}


