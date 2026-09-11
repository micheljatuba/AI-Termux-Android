if [[ $- == *i* && -z ${SSH_CONNECTION:-} && ${TERMUX_AI_GUEST:-0} != 1 && ${TERMUX_AI_NO_MENU:-0} != 1 && -t 0 && -t 1 ]]; then
    if command -v ia >/dev/null 2>&1; then
        command ia || true
    fi
fi