; All the functions follow the System V ABI for amd64 in terms of saving registers,
;    i.e. they will save rsp, rbp, rbx, r12 - r15 (for what a particular function might also save, see its description)
; Global functions related to the long numbers also save the arguments
;
; All the functions that do read something, do that from stdin
; All the functions that do write something, do that to either stdout or stderr,
;    which is reflected in their name and/or description
;
; This file contains 3 groups of functions:
;    - basic I/O functions
;    - basic long number functions (including reading and writing them)
;    - exit noreturn function, which flushes all the buffers with panic on error disabled and exits
;
; Implementation notes for the basic I/O functions:
;    - The writing functions ignore EOF bit in a corresponding I/O meta
;    - The reading functions will not try doing a read syscall if the corresponding EOF bit is set
;    - The functions ignore any syscall error written in a corresponding I/O meta before they were called
;        (which means you don't have to zero the error bits after processing it).
;    - The I/O is buffered and '\n' char doesn't force flush, hence if you need the buffer to be flushed,
;        call a corresponding flush or write_lf_flush function


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


; Add a short number to a long number
; Destroyes: r8, r9
; Args:
;    rdi -- address of the long number
;    rbx -- the short number (64-bit unsigned)
;    rcx -- length of the long number in qwords (MUST be >= 2)
; Result:
;    sum is written to rdi
                global          add_long_short
add_long_short:
                add             qword [rdi], rbx
                jnc             .ret
                lea             r8, [rcx - 1]
                lea             r9, [rdi + 8]
.loop:
                adc             qword [r9], 0
                jnc             .ret
                lea             r9, [r9 + 8]
                dec             r8
                jnz             .loop
.ret:
                ret

; Multiply a long number by a short number
; Destroyes: r8, r9, r10, r11, rax
; Args:
;    rdi -- address of the long number
;    rdx -- the short number (64-bit unsigned)
;    rcx -- length of the long number in qwords
; Result:
;    product is written to rdi
                global          mul_long_short
mul_long_short:
                mov             r8, rcx
                mov             r9, rdi
                xor             r10, r10
.loop:
                mulx            rax, r11, qword [r9]
                add             r11, r10
                adc             rax, 0
                mov             qword [r9], r11
                mov             r10, rax
                add             r9, 8
                dec             r8
                jnz             .loop
                ret

; Divide a long number by a short number
; Destroyes: r8, rax
; Args:
;    rdi -- address of the long number
;    rbx -- the short number (64-bit unsigned)
;    rcx -- length of the long number in qwords
; Result:
;    quotient is written to rdi
;    rdx -- remainder
;    r9 -- non-zero if the quotient is non-zero
                global          div_long_short
div_long_short:
                mov             r8, rcx
                xor             r9, r9
                xor             rdx, rdx
.loop:
                mov             rax, qword [rdi + r8 * 8 - 8]
                div             rbx
                mov             qword [rdi + r8 * 8 - 8], rax
                or              r9, rax
                dec             r8
                jnz             .loop
                ret

; Assign zero to a long number
; Destroyes: rax, r8, r9
; Args:
;    rdi -- address of the long number
;    rcx -- length of the long number in qwords
                global          set_zero
set_zero:
                mov             r8, rdi
                mov             r9, rcx

                xor             rax, rax
                cld
                rep stosq

                mov             rdi, r8
                mov             rcx, r9
                ret

; Check if a long number is zero
; Destroyes: rax, r8, r9
; Args:
;    rdi -- address of the long number
;    rcx -- length of the long number in qwords
; Result:
;    ZF = 1 if zero
                global          is_zero
is_zero:
                mov             r8, rdi
                mov             r9, rcx

                xor             rax, rax
                cld
                rep scasq

                mov             rdi, r8
                mov             rcx, r9
                ret


; Read a long number from stdin
; Destroyes: rax, rsi, rdx, rbx, r8, r9, r10, r11, panic on error flag for stdin
; Args:
;    rdi -- address of the long number
;    rcx -- length of the long number in qwords
; Result:
;    read number is written to rdi
                global          read_long
read_long:
                push            r12
                push            r13
                mov             r12, rdi
                mov             r13, rcx
                call            set_zero
                or              qword [stdin_meta], IO_META_MASK_ERR_PANIC

.loop:
                xor             rbx, rbx
                mov             r8, 19
.read_chunk_loop:
                call            read_char
                test            rax, rax
                js              .done
                cmp             rax, CHAR_LF
                je              .done
                sub             rax, '0'
                cmp             rax, 9
                ja              .invalid_char
                lea             rbx, [rbx + rbx * 4]
                lea             rbx, [rax + rbx * 2]
                dec             r8
                jnz             .read_chunk_loop

                mov             rdi, r12
                mov             rcx, r13
                mov             rdx, pow10_19
                call            mul_long_short
                call            add_long_short
                jmp             .loop
.ret:
                pop             r13
                pop             r12
                ret
.done:
                mov             rdx, qword [pow10_arr_reversed + r8 * 8]
                mov             rdi, r12
                mov             rcx, r13
                cmp             rdx, 1
                je              .ret
                call            mul_long_short
                call            add_long_short
                jmp             .ret
.invalid_char:
                and             qword [stderr_meta], ~IO_META_MASK_ERR_PANIC
                lea             r12, [rax + '0']
                mov             rsi, invalid_char_msg
                mov             rdx, invalid_char_msg_size
                call            stderr_write_string
                mov             r8, r12
                call            stderr_write_char
                call            stderr_write_lf_flush
                and             qword [stdin_meta], ~IO_META_MASK_ERR_PANIC
.skip_loop:
                call            read_char
                test            rax, rax
                js              .skip_loop_end
                cmp             rax, CHAR_LF
                jne             .skip_loop
.skip_loop_end:
                mov             rdi, qword [stdin_meta]
                shr             rdi, 2
                mov             rsi, 1
                cmovz           rdi, rsi
                jmp             exit


; Writes a long number to stdout
; Destroyes: r8, r9, r10, r11, rax, rsi, rdx, rbx, panic on error flag for stdout
; Args:
;    rdi -- address of the long number (the rdi value is saved, but the number is zeroed)
;    rcx -- length of the long number in qwords
                global          write_long
write_long:
                push            r12
                push            rdi
                push            rcx

                mov             r11, rsp
                lea             r12, qword [rcx + rcx * 4]
                shl             r12, 2
                mov             r8, 8
                sub             r8, r12
                and             r8, 7
                add             r12, r8
                sub             rsp, r12

                mov             rcx, r12
                shr             rcx, 3
                mov             rdi, rsp
                mov             rax, qword_packed_ascii_zeroes
                cld
                rep stosq
                mov             rcx, qword [r11]
                mov             rdi, qword [r11 + 8]

                mov             rbx, pow10_19
                mov             r10, magic_num_div10
                xor             rsi, rsi
.loop:
                sub             r11, rsi
                call            div_long_short
                mov             rsi, 19
.chunk_loop:
                mov             r8, rdx
                mulx            rdx, rax, r10
                shr             rdx, 3
                lea             rax, qword [rdx + rdx * 4]
                lea             rax, qword [rax + rax - '0']
                sub             r8, rax
                dec             r11
                mov             byte [r11], r8b
                dec             rsi
                test            rdx, rdx
                jnz             .chunk_loop

                test            r9, r9
                jnz             .loop

                mov             rsi, r11
                lea             rdx, [rsp + r12]
                sub             rdx, r11
                or              qword [stdout_meta], IO_META_MASK_ERR_PANIC
                call            stdout_write_string

                add             rsp, r12
                pop             rcx
                pop             rdi
                pop             r12
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

qword_packed_ascii_zeroes: \
                equ             0x3030303030303030

magic_num_div10: \
                equ             0xcccccccccccccccd

pow10_19: \
                equ             0x8ac7230489e80000

pow10_arr_reversed:
                dq              pow10_19, 0xde0b6b3a7640000, 0x16345785d8a0000, 0x2386f26fc10000, \
                                0x38d7ea4c68000, 0x5af3107a4000, 0x9184e72a000, 0xe8d4a51000, \
                                0x174876e800, 0x2540be400, 0x3b9aca00, 0x5f5e100, 0x989680, 0xf4240, \
                                0x186a0, 0x2710, 0x3e8, 0x64, 0xa, 0x1
pow10_arr_reversed_size: \
                equ             $ - pow10_arr_reversed
