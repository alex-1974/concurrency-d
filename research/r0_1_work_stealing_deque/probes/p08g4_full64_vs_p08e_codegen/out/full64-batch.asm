
research/r0_1_work_stealing_deque/probes/p08g4_full64_vs_p08e_codegen/r0-1-p08g4-full64-vs-p08e-codegen:     Dateiformat elf64-x86-64


Disassembly of section .init:

Disassembly of section .plt:

Disassembly of section .plt.got:

Disassembly of section .text:

0000000000025bc0 <p08g4_full64_batch>:
   25bc0:	48 85 d2             	test   rdx,rdx
   25bc3:	74 55                	je     25c1a <p08g4_full64_batch+0x5a>
   25bc5:	48 8b 0f             	mov    rcx,QWORD PTR [rdi]
   25bc8:	48 8b 47 40          	mov    rax,QWORD PTR [rdi+0x40]
   25bcc:	48 29 c8             	sub    rax,rcx
   25bcf:	48 05 ff fe ff ff    	add    rax,0xfffffffffffffeff
   25bd5:	48 3d 00 ff ff ff    	cmp    rax,0xffffffffffffff00
   25bdb:	72 3d                	jb     25c1a <p08g4_full64_batch+0x5a>
   25bdd:	49 b8 00 00 00 00 00 	movabs r8,0x8000000000000000
   25be4:	00 00 80 
   25be7:	49 31 c8             	xor    r8,rcx
   25bea:	48 89 c8             	mov    rax,rcx
   25bed:	f0 4c 0f b1 07       	lock cmpxchg QWORD PTR [rdi],r8
   25bf2:	75 26                	jne    25c1a <p08g4_full64_batch+0x5a>
   25bf4:	f0 83 4c 24 c0 00    	lock or DWORD PTR [rsp-0x40],0x0
   25bfa:	4c 8b 47 40          	mov    r8,QWORD PTR [rdi+0x40]
   25bfe:	4c 89 c0             	mov    rax,r8
   25c01:	48 29 c8             	sub    rax,rcx
   25c04:	4c 8d 88 ff fe ff ff 	lea    r9,[rax-0x101]
   25c0b:	49 81 f9 00 ff ff ff 	cmp    r9,0xffffffffffffff00
   25c12:	73 09                	jae    25c1d <p08g4_full64_batch+0x5d>
   25c14:	31 c0                	xor    eax,eax
   25c16:	48 89 0f             	mov    QWORD PTR [rdi],rcx
   25c19:	c3                   	ret
   25c1a:	31 c0                	xor    eax,eax
   25c1c:	c3                   	ret
   25c1d:	48 39 c2             	cmp    rdx,rax
   25c20:	48 0f 42 c2          	cmovb  rax,rdx
   25c24:	49 39 c8             	cmp    r8,rcx
   25c27:	0f 84 af 00 00 00    	je     25cdc <p08g4_full64_batch+0x11c>
   25c2d:	4c 8d 40 ff          	lea    r8,[rax-0x1]
   25c31:	89 c2                	mov    edx,eax
   25c33:	83 e2 03             	and    edx,0x3
   25c36:	49 83 f8 03          	cmp    r8,0x3
   25c3a:	73 05                	jae    25c41 <p08g4_full64_batch+0x81>
   25c3c:	45 31 c0             	xor    r8d,r8d
   25c3f:	eb 70                	jmp    25cb1 <p08g4_full64_batch+0xf1>
   25c41:	41 89 c1             	mov    r9d,eax
   25c44:	41 81 e1 fc 01 00 00 	and    r9d,0x1fc
   25c4b:	45 31 c0             	xor    r8d,r8d
   25c4e:	66 90                	xchg   ax,ax
   25c50:	46 8d 14 01          	lea    r10d,[rcx+r8*1]
   25c54:	45 0f b6 d2          	movzx  r10d,r10b
   25c58:	4e 8b 94 d7 80 00 00 	mov    r10,QWORD PTR [rdi+r10*8+0x80]
   25c5f:	00 
   25c60:	4e 89 14 c6          	mov    QWORD PTR [rsi+r8*8],r10
   25c64:	46 8d 14 01          	lea    r10d,[rcx+r8*1]
   25c68:	41 ff c2             	inc    r10d
   25c6b:	45 0f b6 d2          	movzx  r10d,r10b
   25c6f:	4e 8b 94 d7 80 00 00 	mov    r10,QWORD PTR [rdi+r10*8+0x80]
   25c76:	00 
   25c77:	4e 89 54 c6 08       	mov    QWORD PTR [rsi+r8*8+0x8],r10
   25c7c:	46 8d 54 01 02       	lea    r10d,[rcx+r8*1+0x2]
   25c81:	45 0f b6 d2          	movzx  r10d,r10b
   25c85:	4e 8b 94 d7 80 00 00 	mov    r10,QWORD PTR [rdi+r10*8+0x80]
   25c8c:	00 
   25c8d:	4e 89 54 c6 10       	mov    QWORD PTR [rsi+r8*8+0x10],r10
   25c92:	46 8d 54 01 03       	lea    r10d,[rcx+r8*1+0x3]
   25c97:	45 0f b6 d2          	movzx  r10d,r10b
   25c9b:	4e 8b 94 d7 80 00 00 	mov    r10,QWORD PTR [rdi+r10*8+0x80]
   25ca2:	00 
   25ca3:	4e 89 54 c6 18       	mov    QWORD PTR [rsi+r8*8+0x18],r10
   25ca8:	49 83 c0 04          	add    r8,0x4
   25cac:	4d 39 c1             	cmp    r9,r8
   25caf:	75 9f                	jne    25c50 <p08g4_full64_batch+0x90>
   25cb1:	48 85 d2             	test   rdx,rdx
   25cb4:	74 26                	je     25cdc <p08g4_full64_batch+0x11c>
   25cb6:	4a 8d 34 c6          	lea    rsi,[rsi+r8*8]
   25cba:	49 01 c8             	add    r8,rcx
   25cbd:	45 31 c9             	xor    r9d,r9d
   25cc0:	47 8d 14 08          	lea    r10d,[r8+r9*1]
   25cc4:	45 0f b6 d2          	movzx  r10d,r10b
   25cc8:	4e 8b 94 d7 80 00 00 	mov    r10,QWORD PTR [rdi+r10*8+0x80]
   25ccf:	00 
   25cd0:	4e 89 14 ce          	mov    QWORD PTR [rsi+r9*8],r10
   25cd4:	49 ff c1             	inc    r9
   25cd7:	4c 39 ca             	cmp    rdx,r9
   25cda:	75 e4                	jne    25cc0 <p08g4_full64_batch+0x100>
   25cdc:	48 01 c1             	add    rcx,rax
   25cdf:	48 89 0f             	mov    QWORD PTR [rdi],rcx
   25ce2:	c3                   	ret

Disassembly of section .fini:
