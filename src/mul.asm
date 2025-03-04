                section         .text

                global          _start
_start:

                sub             rsp, 2 * MAX_QWORDS * 8
                lea             rdi, [rsp + MAX_QWORDS * 8]
                mov             rcx, MAX_QWORDS
                call            read_long
                mov             rdi, rsp
                call            read_long
                lea             rsi, [rsp + MAX_QWORDS * 8]
                call            add_long_long

                call            write_long

                mov             al, 0x0a
                call            write_char

                jmp             exit

; adds two long numbers
;    rdi -- address of summand #1 (long number)
;    rsi -- address of summand #2 (long number)
;    rcx -- length of long numbers in qwords
; result:
;    sum is written to rdi
add_long_long:
                push            rdi
                push            rsi
                push            rcx

                clc
.loop:
                mov             rax, [rsi]
                lea             rsi, [rsi + 8]
                adc             [rdi], rax
                lea             rdi, [rdi + 8]
                dec             rcx
                jnz             .loop

                pop             rcx
                pop             rsi
                pop             rdi
                ret
