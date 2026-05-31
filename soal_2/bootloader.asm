bits 16
org 0x7C00

jmp start
nop

KERNEL_SEGMENT equ 0x1000
KERNEL_SECTORS equ 15

start:

    cli

    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00

    sti

    ; load kernel into 0x1000:0000

    mov ax, KERNEL_SEGMENT
    mov es, ax

    xor bx, bx

    mov ah, 0x02
    mov al, KERNEL_SECTORS
    mov ch, 0x00
    mov cl, 0x02
    mov dh, 0x00

    ; IMPORTANT:
    ; BIOS already gives boot drive in DL
    ; DO NOT overwrite DL

    int 0x13

    jc disk_error

    cli

    ; kernel segments

    mov ax, KERNEL_SEGMENT
    mov ds, ax
    mov es, ax

    ; safe stack

    mov ax, 0x9000
    mov ss, ax

    mov sp, 0xFFFF
    mov bp, 0xFFFF

    sti

    ; TRUE FAR JMP

    push word KERNEL_SEGMENT
    push word 0x0000
    retf

disk_error:

    mov si, msg

.print:

    lodsb
    or al, al
    jz $

    mov ah, 0x0E
    mov bh, 0x00
    int 0x10

    jmp .print

msg db 'DISK ERROR',0

times 510-($-$$) db 0
dw 0xAA55
