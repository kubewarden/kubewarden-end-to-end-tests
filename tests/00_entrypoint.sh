# Connect to management container
step 'Connecting..'

# disable ctrl-c
trap '' INT

bash --init-file <(
cat << EOF
    # k alias for kubectl
    alias k=kubectl
    complete -F __start_kubectl k
    complete -F __start_kubectl kubectl

    # setup vim a bit
    echo -e "set background=dark\nfiletype plugin indent on\nset tabstop=4\nset shiftwidth=4\nset expandtab" > ~/.vimrc

    # fancy red prompt
    export PS1="\[\e[;31m\][\w]\$ \[\e[m\]"

    # export arrays into subshell
    IP_NODES=(${IP_NODES[@]})
    IP_MASTERS=(${IP_MASTERS[@]})
    IP_WORKERS=(${IP_WORKERS[@]})

    # duplicate output to logfile
    exec &> >(tee -a $OUTPUT)
EOF
# &>/dev/tty to see what you type
) &>/dev/tty ||:
