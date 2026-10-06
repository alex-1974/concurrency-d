
research/r0_1_work_stealing_deque/probes/p08g4_full64_vs_p08e_codegen/r0-1-p08g4-full64-vs-p08e-codegen:     Dateiformat elf64-x86-64


Disassembly of section .init:

Disassembly of section .plt:

Disassembly of section .plt.got:

Disassembly of section .text:

0000000000025aa0 <p08g4_p08e_batch>:
   25aa0:	48 85 d2             	test   rdx,rdx
   25aa3:	74 4f                	je     25af4 <p08g4_p08e_batch+0x54>
   25aa5:	48 8b 0f             	mov    rcx,QWORD PTR [rdi]
   25aa8:	f6 c1 01             	test   cl,0x1
   25aab:	75 47                	jne    25af4 <p08g4_p08e_batch+0x54>
   25aad:	49 89 c8             	mov    r8,rcx
   25ab0:	49 83 c8 01          	or     r8,0x1
   25ab4:	48 89 c8             	mov    rax,rcx
   25ab7:	f0 4c 0f b1 07       	lock cmpxchg QWORD PTR [rdi],r8
   25abc:	75 36                	jne    25af4 <p08g4_p08e_batch+0x54>
   25abe:	f0 83 4c 24 c0 00    	lock or DWORD PTR [rsp-0x40],0x0
   25ac4:	49 89 c8             	mov    r8,rcx
   25ac7:	49 d1 e8             	shr    r8,1
   25aca:	4c 8b 4f 40          	mov    r9,QWORD PTR [rdi+0x40]
   25ace:	4d 29 c1             	sub    r9,r8
   25ad1:	48 b8 ff ff ff ff ff 	movabs rax,0x7fffffffffffffff
   25ad8:	ff ff 7f 
   25adb:	4c 21 c8             	and    rax,r9
   25ade:	4c 8d 88 ff fe ff ff 	lea    r9,[rax-0x101]
   25ae5:	49 81 f9 00 ff ff ff 	cmp    r9,0xffffffffffffff00
   25aec:	73 09                	jae    25af7 <p08g4_p08e_batch+0x57>
   25aee:	31 c0                	xor    eax,eax
   25af0:	48 89 0f             	mov    QWORD PTR [rdi],rcx
   25af3:	c3                   	ret
   25af4:	31 c0                	xor    eax,eax
   25af6:	c3                   	ret
   25af7:	48 39 c2             	cmp    rdx,rax
   25afa:	48 0f 42 c2          	cmovb  rax,rdx
   25afe:	48 8d 50 ff          	lea    rdx,[rax-0x1]
   25b02:	89 c1                	mov    ecx,eax
   25b04:	83 e1 03             	and    ecx,0x3
   25b07:	48 83 fa 03          	cmp    rdx,0x3
   25b0b:	73 04                	jae    25b11 <p08g4_p08e_batch+0x71>
   25b0d:	31 d2                	xor    edx,edx
   25b0f:	eb 70                	jmp    25b81 <p08g4_p08e_batch+0xe1>
   25b11:	41 89 c1             	mov    r9d,eax
   25b14:	41 81 e1 fc 01 00 00 	and    r9d,0x1fc
   25b1b:	31 d2                	xor    edx,edx
   25b1d:	0f 1f 00             	nop    DWORD PTR [rax]
   25b20:	45 8d 14 10          	lea    r10d,[r8+rdx*1]
   25b24:	45 0f b6 d2          	movzx  r10d,r10b
   25b28:	4e 8b 94 d7 80 00 00 	mov    r10,QWORD PTR [rdi+r10*8+0x80]
   25b2f:	00 
   25b30:	4c 89 14 d6          	mov    QWORD PTR [rsi+rdx*8],r10
   25b34:	45 8d 14 10          	lea    r10d,[r8+rdx*1]
   25b38:	41 ff c2             	inc    r10d
   25b3b:	45 0f b6 d2          	movzx  r10d,r10b
   25b3f:	4e 8b 94 d7 80 00 00 	mov    r10,QWORD PTR [rdi+r10*8+0x80]
   25b46:	00 
   25b47:	4c 89 54 d6 08       	mov    QWORD PTR [rsi+rdx*8+0x8],r10
   25b4c:	45 8d 54 10 02       	lea    r10d,[r8+rdx*1+0x2]
   25b51:	45 0f b6 d2          	movzx  r10d,r10b
   25b55:	4e 8b 94 d7 80 00 00 	mov    r10,QWORD PTR [rdi+r10*8+0x80]
   25b5c:	00 
   25b5d:	4c 89 54 d6 10       	mov    QWORD PTR [rsi+rdx*8+0x10],r10
   25b62:	45 8d 54 10 03       	lea    r10d,[r8+rdx*1+0x3]
   25b67:	45 0f b6 d2          	movzx  r10d,r10b
   25b6b:	4e 8b 94 d7 80 00 00 	mov    r10,QWORD PTR [rdi+r10*8+0x80]
   25b72:	00 
   25b73:	4c 89 54 d6 18       	mov    QWORD PTR [rsi+rdx*8+0x18],r10
   25b78:	48 83 c2 04          	add    rdx,0x4
   25b7c:	49 39 d1             	cmp    r9,rdx
   25b7f:	75 9f                	jne    25b20 <p08g4_p08e_batch+0x80>
   25b81:	48 85 c9             	test   rcx,rcx
   25b84:	74 26                	je     25bac <p08g4_p08e_batch+0x10c>
   25b86:	48 8d 34 d6          	lea    rsi,[rsi+rdx*8]
   25b8a:	4c 01 c2             	add    rdx,r8
   25b8d:	45 31 c9             	xor    r9d,r9d
   25b90:	46 8d 14 0a          	lea    r10d,[rdx+r9*1]
   25b94:	45 0f b6 d2          	movzx  r10d,r10b
   25b98:	4e 8b 94 d7 80 00 00 	mov    r10,QWORD PTR [rdi+r10*8+0x80]
   25b9f:	00 
   25ba0:	4e 89 14 ce          	mov    QWORD PTR [rsi+r9*8],r10
   25ba4:	49 ff c1             	inc    r9
   25ba7:	4c 39 c9             	cmp    rcx,r9
   25baa:	75 e4                	jne    25b90 <p08g4_p08e_batch+0xf0>
   25bac:	49 01 c0             	add    r8,rax
   25baf:	4d 01 c0             	add    r8,r8
   25bb2:	4c 89 07             	mov    QWORD PTR [rdi],r8
   25bb5:	c3                   	ret

Disassembly of section .fini:
