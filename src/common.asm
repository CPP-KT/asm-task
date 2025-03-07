MAX_QWORDS:     equ             128

IO_BUF_CAP:     equ             8192

SYSCALL_READ:   equ             0
SYSCALL_WRITE:  equ             1
SYSCALL_EXIT:   equ             0x3c

FD_STDIN:       equ             0
FD_STDOUT:      equ             1
FD_STDERR:      equ             2

CHAR_LF:        equ             0x0a

; see stdin_meta/stdout_meta/stderr_meta
IO_META_MASK_EOF: \
                equ             0b00000000000001
IO_META_MASK_ERR_PANIC: \
                equ             0b00000000000010
IO_META_MASK_ERR: \
                equ             0b11111111111100


                section         .text


; Update I/O meta with syscall error from rax and panic if the meta demands so
;    %1 -- stream name
;    %2 -- register (NOT rax) used to store qword [%1_meta] (stores the latest value at %4)
;    %3 -- register used to store (-rax) << 2
;    %4 -- where to jump if shoudn't panic
;    %5 -- error message label (%5_size must be defined as the size of the message) (in case of panic)
%macro          __prcs_io_err   5

                mov             %2, qword [%1_meta]
                lea             %3, [rax * 4]
                neg             %3
                and             %2, ~IO_META_MASK_ERR
                or              %2, %3
                mov             qword [%1_meta], %2
                test            %2, IO_META_MASK_ERR_PANIC
                jz              %4
                mov             rsi, %5
                mov             rdx, %5_size
                jmp             __perror_exit

%endmacro


; Read from stdin into its buffer
; Destroyes: rdi, rsi, rdx, syscall-destroyed regs (rcx, r11)
; Result:
;    rax -- read bytes amount (equals 0 if got EOF, -errno if got a syscall error)
stdin_buf_read:
                xor             rax, rax ; mov rax, SYSCALL_READ
                test            qword [stdin_meta], IO_META_MASK_EOF
                jnz             .ret
                xor             rdi, rdi ; mov rdi, FD_STDIN
                mov             rsi, stdin_buf
                mov             rdx, IO_BUF_CAP
                syscall
                test            rax, rax
                js              .err
                setz            dl
                or              byte [stdin_meta], dl
                mov             qword [stdin_buf_data_begin], stdin_buf
                lea             rdi, qword [stdin_buf + rax]
                mov             qword [stdin_buf_data_end], rdi
.ret:
                ret
.err:
                __prcs_io_err   stdin, rdi, rsi, .ret, read_err_msg

; Read a char from stdin (buffered)
; Destroyes: rdi, rsi, rdx, syscall-destroyed regs (rcx, r11)
; Result:
;    rax -- the char (-1 on EOF or error)
read_char:
                mov             rdi, qword [stdin_buf_data_end]
                cmp             qword [stdin_buf_data_begin], rdi
                jae             .read
.get_char:
                mov             rax, qword [stdin_buf_data_begin]
                movzx           rax, byte [rax]
                inc             qword [stdin_buf_data_begin]
                ret
.read:
                call            stdin_buf_read
                cmp             rax, 0
                jg              .get_char
                mov             rax, -1
                ret


; Write syscall wrapper: writes all the data to the file (does nothing if rdx == 0)
; Destroyes: rax, rsi, rdx, syscall-destroyed regs (rcx, r11)
; Args:
;    rdi [saved]                     -- the file descriptor
;    rsi [out: rsi + <written_size>] -- pointer to the data
;    rdx [out: rdx - <written_size>] -- the data size
;        (may be > 0 at the end only if an error occurred)
; Result:
;    rax -- < 0 if an error occurred, >= 0 otherwise
;        (a return value of the last write syscall or 0 if rdx == 0)
sys_write:
                test            rdx, rdx
                jz              .ret0
.loop:
                mov             rax, SYSCALL_WRITE
                syscall
                test            rax, rax
                js              .ret
                add             rsi, rax
                sub             rdx, rax
                jnz             .loop
.ret:
                ret
.ret0:
                xor             rax, rax
                ret

; Basically just flush, but resets begin and end iters if only 1 char is left to be written
; Args:
;    %1 -- stream name
%macro          __wchar_flush   1

                call            %1_flush
                test            rax, rax
                jns             %%skip
                dec             qword [%1_buf_data_end]
                cmp             rdx, 1
                jne             %%skip
                mov             qword [%1_buf_data_begin], %1_buf
                mov             qword [%1_buf_data_end], %1_buf
%%skip:

%endmacro

; Declare global functions to work with stdout/stderr
; Args:
;    %1 -- target name
;    %2 -- target file descriptor
%macro          __decl_out_syms 2

; Write all the buffered data to %1
; Destroyes: rdi, rsi, rdx, syscall-destroyed regs (rcx, r11)
; Result:
;    rax      -- < 0 if an error occurred, >= 0 otherwise
;        (a return value of the last write syscall or 0 if had nothing to write)
;    rsi, rdx -- as for sys_write(qword [%1_buf_data_begin], qword [%1_buf_data_end] - qword [%1_buf_data_begin])
%1_flush:
                mov             rdi, %2
                mov             rsi, qword [%1_buf_data_begin]
                mov             rdx, qword [%1_buf_data_end]
                sub             rdx, rsi
                call            sys_write
                test            rax, rax
                js              .err
                mov             qword [%1_buf_data_begin], %1_buf
                mov             qword [%1_buf_data_end], %1_buf
                ret
.ret_with_err:
                mov             qword [%1_buf_data_begin], rsi
                ret
.err:
                __prcs_io_err   %1, rdi, rdx, .ret_with_err, write_err_msg

; Write char to %1 (buffered)
; Destroyes: rdi, rsi, rdx, syscall-destroyed regs (rcx, r11)
; Args:
;    r8b [saved] -- the char
; Result:
;    rax -- < 0 if an error occurred, >= 0 otherwise
;        (a return value of the last write syscall or 0 if needed no syscall)
%1_write_char:
                mov             rax, qword [%1_buf_data_end]
                mov             byte [rax], r8b
                inc             qword [%1_buf_data_end]
                cmp             qword [%1_buf_data_end], %1_buf_cap_end
                ja              .flush
                xor             rax, rax
                ret
.flush:
                __wchar_flush   %1
                ret

; Write '\n' and flush
; Destroyes: rdi, rsi, rdx, syscall-destroyed regs (rcx, r11)
; Result:
;    rax -- < 0 if an error occurred, >= 0 otherwise (a return value of the last write syscall)
%1_write_lf_flush:
                mov             rax, qword [%1_buf_data_end]
                mov             byte [rax], CHAR_LF
                inc             qword [%1_buf_data_end]
                __wchar_flush   %1
                ret

; Write string to %1 (buffered, does nothing if rdx == 0)
; Destroyes: r8, r9, rax, rdi, rsi, rdx, syscall-destroyed regs (rcx, r11)
; Args:
;    rsi [out: rsi + <written_size>] -- pointer to the string
;    rdx [out: rdx - <written_size>] -- the string length
; Result:
;    rax -- < 0 if an error occurred, >= 0 otherwise
;        (a return value of the last write syscall or 0 if needed no syscall)
%1_write_string:
                test            rdx, rdx
                jz              .ret0
                mov             rax, %1_buf_cap_end
                sub             rax, qword [%1_buf_data_end]
                cmp             rdx, rax
                ja              .write
                mov             rcx, rdx
                mov             rdi, qword [%1_buf_data_end]
                cld
                rep movsb
                mov             qword [%1_buf_data_end], rdi
                xor             rdx, rdx
                xor             rax, rax
                ret
.write:
                mov             r8, rsi
                mov             r9, rdx
                call            %1_flush
                test            rax, rax
                js              .ret
                mov             rsi, r8
                mov             rdx, r9
                call            sys_write
                test            rax, rax
                js              .sys_write_err
.ret:
                ret
.sys_write_err:
                __prcs_io_err   %1, rdi, rcx, .ret, write_err_msg
.ret0:
                xor             rax, rax
                ret

%endmacro       ; __decl_out_syms

                __decl_out_syms stdout, FD_STDOUT
                __decl_out_syms stderr, FD_STDERR


; adds a short number to a long number
;    rdi -- address of summand #1 (long number)
;    rax -- summand #2 (64-bit unsigned)
;    rcx -- length of long number in qwords
; result:
;    sum is written to rdi
add_long_short:
                push            rdi
                push            rcx
                push            rdx

                xor             rdx, rdx
.loop:
                add             [rdi], rax
                adc             rdx, 0
                mov             rax, rdx
                xor             rdx, rdx
                add             rdi, 8
                dec             rcx
                jnz             .loop

                pop             rdx
                pop             rcx
                pop             rdi
                ret

; multiplies a long number by a short number
;    rdi -- address of multiplier #1 (long number)
;    rbx -- multiplier #2 (64-bit unsigned)
;    rcx -- length of long number in qwords
; result:
;    product is written to rdi
mul_long_short:
                push            rax
                push            rdi
                push            rcx

                xor             rsi, rsi
.loop:
                mov             rax, [rdi]
                mul             rbx
                add             rax, rsi
                adc             rdx, 0
                mov             [rdi], rax
                add             rdi, 8
                mov             rsi, rdx
                dec             rcx
                jnz             .loop

                pop             rcx
                pop             rdi
                pop             rax
                ret

; divides a long number by a short number
;    rdi -- address of dividend (long number)
;    rbx -- divisor (64-bit unsigned)
;    rcx -- length of long number in qwords
; result:
;    quotient is written to rdi
;    remainder is written to rdx
div_long_short:
                push            rdi
                push            rax
                push            rcx

                lea             rdi, [rdi + 8 * rcx - 8]
                xor             rdx, rdx

.loop:
                mov             rax, [rdi]
                div             rbx
                mov             [rdi], rax
                sub             rdi, 8
                dec             rcx
                jnz             .loop

                pop             rcx
                pop             rax
                pop             rdi
                ret

; assigns zero to a long number
;    rdi -- argument (long number)
;    rcx -- length of long number in qwords
set_zero:
                push            rax
                push            rdi
                push            rcx

                xor             rax, rax
                rep stosq

                pop             rcx
                pop             rdi
                pop             rax
                ret

; checks if a long number is zero
;    rdi -- argument (long number)
;    rcx -- length of long number in qwords
; result:
;    ZF=1 if zero
is_zero:
                push            rax
                push            rdi
                push            rcx

                xor             rax, rax
                rep scasq

                pop             rcx
                pop             rdi
                pop             rax
                ret

; reads a long number from stdin
;    rdi -- location for output (long number)
;    rcx -- length of long number in qwords
read_long:
                push            rcx
                push            rdi

                call            set_zero
                or              qword [stdin_meta], IO_META_MASK_ERR_PANIC
.loop:
                call            read_char
                or              rax, rax
                js              exit
                cmp             rax, 0x0a
                je              .done
                cmp             rax, '0'
                jb              .invalid_char
                cmp             rax, '9'
                ja              .invalid_char

                sub             rax, '0'
                mov             rbx, 10
                mov             rdi, qword [rsp]
                mov             rcx, qword [rsp + 8]
                call            mul_long_short
                call            add_long_short
                jmp             .loop

.done:
                pop             rdi
                pop             rcx
                ret

.invalid_char:
                mov             rsi, invalid_char_msg
                mov             rdx, invalid_char_msg_size
                mov             r12, rax
                call            stderr_write_string
                mov             r8, r12
                call            stderr_write_char
                call            stderr_write_lf_flush

.skip_loop:
                call            read_char
                or              rax, rax
                js              exit
                cmp             rax, 0x0a
                je              exit
                jmp             .skip_loop

; writes a long number to stdout
;    rdi -- argument (long number)
;    rcx -- length of long number in qwords
write_long:
                push            rax
                push            rcx

                mov             rax, 20
                mul             rcx
                mov             rbp, rsp
                sub             rsp, rax

                mov             rsi, rbp

.loop:
                mov             rbx, 10
                call            div_long_short
                add             rdx, '0'
                dec             rsi
                mov             [rsi], dl
                call            is_zero
                jnz             .loop

                mov             rdx, rbp
                sub             rdx, rsi
                or              qword [stdout_meta], IO_META_MASK_ERR_PANIC
                call            stdout_write_string

                mov             rsp, rbp
                pop             rcx
                pop             rax
                ret


; [noreturn] exit
; Args:
;    rdi -- error code
exit:
                mov             r12, rdi
                and             qword [stdout_meta], ~IO_META_MASK_ERR_PANIC
                and             qword [stderr_meta], ~IO_META_MASK_ERR_PANIC
                call            stdout_flush
                call            stderr_flush
                mov             rdi, r12
                mov             rax, SYSCALL_EXIT
                syscall

; [noreturn] print message to stderr & exit
; Args:
;    rax -- negated error code (because it's designed to be called if syscall fails)
;    rsi -- msg
;    rdx -- msg size
__perror_exit:
                and             qword [stderr_meta], ~IO_META_MASK_ERR_PANIC
                mov             r12, rax
                neg             r12
                call            stderr_write_string
                mov             rdi, r12
                jmp             exit


; Define all the symbols for an I/O stream
; Args:
;    %1 -- stream nams
;    %2 -- buffer size (actual size would be %2 + 1 to simplify pushing single chars into the buffer)
%macro          __decl_io_symb  2

                section         .bss

%1_buf:
                resb            %2 + 1

                section         .data

%1_buf_data_begin:
                dq              %1_buf
%1_buf_data_end:
                dq              %1_buf

; Meta-information about stdin/stdout/stderr (each points to a qword with starting value = 0b10)
; Content (from the highest to the lowest bit):
; | 50 bits -- reserved | 12 bits -- syscall error | 1 bit -- print error message and exit on a syscall error | 1 bit -- EOF bit |
%1_meta:
                dq              0b10

%1_buf_cap_end: \
                equ             %1_buf + %2

%endmacro

; Define a string and its size
;    %1 -- label name
;    %2 -- the string content
%macro          __decl_str        2+
%1:
                db              %2
%1_size: \
                equ             $ - %1
%endmacro

                __decl_io_symb  stdin, IO_BUF_CAP
                __decl_io_symb  stdout, IO_BUF_CAP
                __decl_io_symb  stderr, IO_BUF_CAP


                section         .rodata

                __decl_str      invalid_char_msg, "Invalid character: "

                __decl_str      read_err_msg, "Got an error when was trying to read the input", CHAR_LF
                __decl_str      write_err_msg, "Got an error when was trying to write", CHAR_LF
