/*
 * This file is part of RGBDS.
 *
 * Copyright (c) 1997-2019, Carsten Sorensen and RGBDS contributors.
 *
 * SPDX-License-Identifier: MIT
 */

%{
#include <ctype.h>
#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "asm/charmap.h"
#include "asm/fixpoint.h"
#include "asm/format.h"
#include "asm/fstack.h"
#include "asm/lexer.h"
#include "asm/macro.h"
#include "asm/main.h"
#include "asm/opt.h"
#include "asm/output.h"
#include "asm/rpn.h"
#include "asm/section.h"
#include "asm/symbol.h"
#include "asm/util.h"
#include "asm/warning.h"

#include "extern/utf8decoder.h"

#include "linkdefs.h"
#include "platform.h" // strncasecmp, strdup

static struct CaptureBody captureBody; /* Captures a REPT/FOR or MACRO */

static void upperstring(char *dest, char const *src)
{
	while (*src)
		*dest++ = toupper(*src++);
	*dest = '\0';
}

static void lowerstring(char *dest, char const *src)
{
	while (*src)
		*dest++ = tolower(*src++);
	*dest = '\0';
}

static uint32_t str2int2(uint8_t *s, int32_t length)
{
	int32_t i;
	uint32_t r = 0;

	i = length < 4 ? 0 : length - 4;
	while (i < length) {
		r <<= 8;
		r |= s[i];
		i++;
	}

	return r;
}

static char *strrstr(char *s1, char *s2)
{
	size_t len1 = strlen(s1);
	size_t len2 = strlen(s2);

	if (len2 > len1)
		return NULL;

	for (char *p = s1 + len1 - len2; p >= s1; p--)
		if (!strncmp(p, s2, len2))
			return p;

	return NULL;
}

static size_t strlenUTF8(const char *s)
{
	size_t len = 0;
	uint32_t state = 0;
	uint32_t codep = 0;

	while (*s) {
		switch (decode(&state, &codep, *s)) {
		case 1:
			fatalerror("STRLEN: Invalid UTF-8 character\n");
			break;
		case 0:
			len++;
			break;
		}
		s++;
	}

	/* Check for partial code point. */
	if (state != 0)
		fatalerror("STRLEN: Invalid UTF-8 character\n");

	return len;
}

static void strsubUTF8(char *dest, size_t destLen, const char *src, uint32_t pos, uint32_t len)
{
	size_t srcIndex = 0;
	size_t destIndex = 0;
	uint32_t state = 0;
	uint32_t codep = 0;
	uint32_t curPos = 1;
	uint32_t curLen = 0;

	if (pos < 1) {
		warning(WARNING_BUILTIN_ARG, "STRSUB: Position starts at 1\n");
		pos = 1;
	}

	/* Advance to starting position in source string. */
	while (src[srcIndex] && curPos < pos) {
		switch (decode(&state, &codep, src[srcIndex])) {
		case 1:
			fatalerror("STRSUB: Invalid UTF-8 character\n");
			break;
		case 0:
			curPos++;
			break;
		}
		srcIndex++;
	}

	if (!src[srcIndex] && len)
		warning(WARNING_BUILTIN_ARG,
			"STRSUB: Position %lu is past the end of the string\n",
			(unsigned long)pos);

	/* Copy from source to destination. */
	while (src[srcIndex] && destIndex < destLen - 1 && curLen < len) {
		switch (decode(&state, &codep, src[srcIndex])) {
		case 1:
			fatalerror("STRSUB: Invalid UTF-8 character\n");
			break;
		case 0:
			curLen++;
			break;
		}
		dest[destIndex++] = src[srcIndex++];
	}

	if (curLen < len)
		warning(WARNING_BUILTIN_ARG, "STRSUB: Length too big: %lu\n", (unsigned long)len);

	/* Check for partial code point. */
	if (state != 0)
		fatalerror("STRSUB: Invalid UTF-8 character\n");

	dest[destIndex] = '\0';
}

static void strrpl(char *dest, size_t destLen, char const *src, char const *old, char const *new)
{
	size_t oldLen = strlen(old);
	size_t newLen = strlen(new);
	size_t i = 0;

	if (!oldLen) {
		warning(WARNING_EMPTY_STRRPL, "STRRPL: Cannot replace an empty string\n");
		strcpy(dest, src);
		return;
	}

	for (char const *next = strstr(src, old); next && *next; next = strstr(src, old)) {
		// Copy anything before the substring to replace
		unsigned int lenBefore = next - src;

		memcpy(dest + i, src, lenBefore < destLen - i ? lenBefore : destLen - i);
		i += next - src;
		if (i >= destLen)
			break;

		// Copy the replacement substring
		memcpy(dest + i, new, newLen < destLen - i ? newLen : destLen - i);
		i += newLen;
		if (i >= destLen)
			break;

		src = next + oldLen;
	}

	if (i < destLen) {
		size_t srcLen = strlen(src);

		// Copy anything after the last replaced substring
		memcpy(dest + i, src, srcLen < destLen - i ? srcLen : destLen - i);
		i += srcLen;
	}

	if (i >= destLen) {
		warning(WARNING_LONG_STR, "STRRPL: String too long, got truncated\n");
		i = destLen - 1;
	}
	dest[i] = '\0';
}

static void initStrFmtArgList(struct StrFmtArgList *args)
{
	args->nbArgs = 0;
	args->capacity = INITIAL_STRFMT_ARG_SIZE;
	args->args = malloc(args->capacity * sizeof(*args->args));
	if (!args->args)
		fatalerror("Failed to allocate memory for STRFMT arg list: %s\n",
			   strerror(errno));
}

static size_t nextStrFmtArgListIndex(struct StrFmtArgList *args)
{
	if (args->nbArgs == args->capacity) {
		args->capacity = (args->capacity + 1) * 2;
		args->args = realloc(args->args, args->capacity * sizeof(*args->args));
		if (!args->args)
			fatalerror("realloc error while resizing STRFMT arg list: %s\n",
				   strerror(errno));
	}
	return args->nbArgs++;
}

static void freeStrFmtArgList(struct StrFmtArgList *args)
{
	free(args->format);
	for (size_t i = 0; i < args->nbArgs; i++)
		if (!args->args[i].isNumeric)
			free(args->args[i].string);
	free(args->args);
}

static void strfmt(char *dest, size_t destLen, char const *fmt, size_t nbArgs, struct StrFmtArg *args)
{
	size_t a = 0;
	size_t i = 0;

	while (i < destLen) {
		int c = *fmt++;

		if (c == '\0') {
			break;
		} else if (c != '%') {
			dest[i++] = c;
			continue;
		}

		c = *fmt++;

		if (c == '%') {
			dest[i++] = c;
			continue;
		}

		struct FormatSpec spec = fmt_NewSpec();

		while (c != '\0') {
			fmt_UseCharacter(&spec, c);
			if (fmt_IsFinished(&spec))
				break;
			c = *fmt++;
		}

		if (fmt_IsEmpty(&spec)) {
			error("STRFMT: Illegal '%%' at end of format string\n");
			dest[i++] = '%';
			break;
		} else if (!fmt_IsValid(&spec)) {
			error("STRFMT: Invalid format spec for argument %zu\n", a + 1);
			dest[i++] = '%';
			a++;
			continue;
		} else if (a >= nbArgs) {
			// Will warn after formatting is done.
			dest[i++] = '%';
			a++;
			continue;
		}

		struct StrFmtArg *arg = &args[a++];
		static char buf[MAXSTRLEN + 1];

		if (arg->isNumeric)
			fmt_PrintNumber(buf, sizeof(buf), &spec, arg->number);
		else
			fmt_PrintString(buf, sizeof(buf), &spec, arg->string);

		i += snprintf(&dest[i], destLen - i, "%s", buf);
	}

	if (a < nbArgs)
		error("STRFMT: %zu unformatted argument(s)\n", nbArgs - a);
	else if (a > nbArgs)
		error("STRFMT: Not enough arguments for format spec, got: %zu, need: %zu\n", nbArgs, a);

	if (i > destLen - 1) {
		warning(WARNING_LONG_STR, "STRFMT: String too long, got truncated\n");
		i = destLen - 1;
	}
	dest[i] = '\0';
}

static void initDsArgList(struct DsArgList *args)
{
	args->nbArgs = 0;
	args->capacity = INITIAL_DS_ARG_SIZE;
	args->args = malloc(args->capacity * sizeof(*args->args));
	if (!args->args)
		fatalerror("Failed to allocate memory for ds arg list: %s\n",
			   strerror(errno));
}

static size_t nextDsArgListIndex(struct DsArgList *args)
{
	if (args->nbArgs == args->capacity) {
		args->capacity = (args->capacity + 1) * 2;
		args->args = realloc(args->args, args->capacity * sizeof(*args->args));
		if (!args->args)
			fatalerror("realloc error while resizing ds arg list: %s\n",
				   strerror(errno));
	}
	return args->nbArgs++;
}

static void freeDsArgList(struct DsArgList *args)
{
	free(args->args);
}

static inline void failAssert(enum AssertionType type)
{
	switch (type) {
		case ASSERT_FATAL:
			fatalerror("Assertion failed\n");
		case ASSERT_ERROR:
			error("Assertion failed\n");
			break;
		case ASSERT_WARN:
			warning(WARNING_ASSERT, "Assertion failed\n");
			break;
	}
}

static inline void failAssertMsg(enum AssertionType type, char const *msg)
{
	switch (type) {
		case ASSERT_FATAL:
			fatalerror("Assertion failed: %s\n", msg);
		case ASSERT_ERROR:
			error("Assertion failed: %s\n", msg);
			break;
		case ASSERT_WARN:
			warning(WARNING_ASSERT, "Assertion failed: %s\n", msg);
			break;
	}
}

void yyerror(char const *str)
{
	error("%s\n", str);
}

// The CPU encodes instructions in a logical way, so most instructions actually follow patterns.
// These enums thus help with bit twiddling to compute opcodes
enum {
	REG_B = 0,
	REG_C,
	REG_D,
	REG_E,
	REG_H,
	REG_L,
	REG_HL_IND,
	REG_A
};

enum {
	REG_BC_IND = 0,
	REG_DE_IND,
	REG_HL_INDINC,
	REG_HL_INDDEC,
};

enum {
	REG_BC = 0,
	REG_DE = 1,
	REG_HL = 2,
	REG_SP = 3,
	REG_AF = 3
};

enum {
	CC_NZ = 0,
	CC_Z,
	CC_NC,
	CC_C
};

%}

%union
{
	char tzSym[MAXSYMLEN + 1];
	char tzString[MAXSTRLEN + 1];
	struct Expression sVal;
	int32_t nConstValue;
	enum SectionModifier sectMod;
	struct SectionSpec sectSpec;
	struct MacroArgs *macroArg;
	enum AssertionType assertType;
	struct DsArgList dsArgs;
	struct {
		int32_t start;
		int32_t stop;
		int32_t step;
	} forArgs;
	struct StrFmtArgList strfmtArgs;
}

%type	<sVal>		relocexpr
%type	<sVal>		relocexpr_no_str
%type	<nConstValue>	const
%type	<nConstValue>	const_no_str
%type	<nConstValue>	uconst
%type	<nConstValue>	rs_uconst
%type	<nConstValue>	const_3bit
%type	<sVal>		reloc_8bit
%type	<sVal>		reloc_8bit_no_str
%type	<sVal>		reloc_16bit
%type	<sVal>		reloc_16bit_no_str
%type	<nConstValue>	sectiontype

%type	<tzString>	string
%type	<tzString>	strcat_args
%type	<strfmtArgs>	strfmt_args
%type	<strfmtArgs>	strfmt_va_args

%type	<nConstValue>	sectorg
%type	<sectSpec>	sectattrs

%token	<nConstValue>	T_NUMBER "number"
%token	<tzString>	T_STRING "string"

%token	T_PERIOD "."
%token	T_COMMA ","
%token	T_COLON ":"
%token	T_LBRACK "[" T_RBRACK "]"
%token	T_LPAREN "(" T_RPAREN ")"
%token	T_NEWLINE "newline"

%token	T_OP_LOGICNOT "!"
%token	T_OP_LOGICAND "&&" T_OP_LOGICOR "||"
%token	T_OP_LOGICGT ">" T_OP_LOGICLT "<"
%token	T_OP_LOGICGE ">=" T_OP_LOGICLE "<="
%token	T_OP_LOGICNE "!=" T_OP_LOGICEQU "=="
%token	T_OP_ADD "+" T_OP_SUB "-"
%token	T_OP_OR "|" T_OP_XOR "^" T_OP_AND "&"
%token	T_OP_SHL "<<" T_OP_SHR ">>"
%token	T_OP_MUL "*" T_OP_DIV "/" T_OP_MOD "%"
%token	T_OP_NOT "~"
%left	T_OP_LOGICOR
%left	T_OP_LOGICAND
%left	T_OP_LOGICGT T_OP_LOGICLT T_OP_LOGICGE T_OP_LOGICLE T_OP_LOGICNE T_OP_LOGICEQU
%left	T_OP_ADD T_OP_SUB
%left	T_OP_OR T_OP_XOR T_OP_AND
%left	T_OP_SHL T_OP_SHR
%left	T_OP_MUL T_OP_DIV T_OP_MOD

%precedence	NEG /* negation -- unary minus */

%token	T_OP_EXP "**"
%left	T_OP_EXP

%token	T_OP_DEF "DEF"
%token	T_OP_BANK "BANK"
%token	T_OP_ALIGN "ALIGN"
%token	T_OP_SIN "SIN" T_OP_COS "COS" T_OP_TAN "TAN"
%token	T_OP_ASIN "ASIN" T_OP_ACOS "ACOS" T_OP_ATAN "ATAN" T_OP_ATAN2 "ATAN2"
%token	T_OP_FDIV "FDIV"
%token	T_OP_FMUL "FMUL"
%token	T_OP_POW "POW"
%token	T_OP_LOG "LOG"
%token	T_OP_ROUND "ROUND"
%token	T_OP_CEIL "CEIL" T_OP_FLOOR "FLOOR"

%token	T_OP_HIGH "HIGH" T_OP_LOW "LOW"
%token	T_OP_ISCONST "ISCONST"

%token	T_OP_STRCMP "STRCMP"
%token	T_OP_STRIN "STRIN" T_OP_STRRIN "STRRIN"
%token	T_OP_STRSUB "STRSUB"
%token	T_OP_STRLEN "STRLEN"
%token	T_OP_STRCAT "STRCAT"
%token	T_OP_STRUPR "STRUPR" T_OP_STRLWR "STRLWR"
%token	T_OP_STRRPL "STRRPL"
%token	T_OP_STRFMT "STRFMT"

%token	<tzSym> T_LABEL "label"
%token	<tzSym> T_ID "identifier"
%token	<tzSym> T_LOCAL_ID "local identifier"
%token	<tzSym> T_ANON "anonymous label"
%type	<tzSym> def_id
%type	<tzSym> redef_id
%type	<tzSym> scoped_id
%type	<tzSym> scoped_anon_id
%token	T_POP_EQU "EQU"
%token	T_POP_SET "SET"
%token	T_POP_EQUAL "="
%token	T_POP_EQUS "EQUS"

%token	T_POP_INCLUDE "INCLUDE"
%token	T_POP_PRINT "PRINT" T_POP_PRINTLN "PRINTLN"
%token	T_POP_PRINTF "PRINTF" T_POP_PRINTT "PRINTT" T_POP_PRINTV "PRINTV" T_POP_PRINTI "PRINTI"
%token	T_POP_IF "IF" T_POP_ELIF "ELIF" T_POP_ELSE "ELSE" T_POP_ENDC "ENDC"
%token	T_POP_EXPORT "EXPORT"
%token	T_POP_DB "DB" T_POP_DS "DS" T_POP_DW "DW" T_POP_DL "DL"
%token	T_POP_SECTION "SECTION" T_POP_FRAGMENT "FRAGMENT"
%token	T_POP_RB "RB" T_POP_RW "RW" // There is no T_POP_RL, only T_Z80_RL
%token	T_POP_MACRO "MACRO"
%token	T_POP_ENDM "ENDM"
%token	T_POP_RSRESET "RSRESET" T_POP_RSSET "RSSET"
%token	T_POP_UNION "UNION" T_POP_NEXTU "NEXTU" T_POP_ENDU "ENDU"
%token	T_POP_INCBIN "INCBIN" T_POP_REPT "REPT" T_POP_FOR "FOR"
%token	T_POP_CHARMAP "CHARMAP"
%token	T_POP_NEWCHARMAP "NEWCHARMAP"
%token	T_POP_SETCHARMAP "SETCHARMAP"
%token	T_POP_PUSHC "PUSHC"
%token	T_POP_POPC "POPC"
%token	T_POP_SHIFT "SHIFT"
%token	T_POP_ENDR "ENDR"
%token	T_POP_BREAK "BREAK"
%token	T_POP_LOAD "LOAD" T_POP_ENDL "ENDL"
%token	T_POP_FAIL "FAIL"
%token	T_POP_WARN "WARN"
%token	T_POP_FATAL "FATAL"
%token	T_POP_ASSERT "ASSERT" T_POP_STATIC_ASSERT "STATIC_ASSERT"
%token	T_POP_PURGE "PURGE"
%token	T_POP_REDEF "REDEF"
%token	T_POP_POPS "POPS"
%token	T_POP_PUSHS "PUSHS"
%token	T_POP_POPO "POPO"
%token	T_POP_PUSHO "PUSHO"
%token	T_POP_OPT "OPT"
%token	T_SECT_ROM0 "ROM0" T_SECT_ROMX "ROMX"
%token	T_SECT_WRAM0 "WRAM0" T_SECT_WRAMX "WRAMX" T_SECT_HRAM "HRAM"
%token	T_SECT_VRAM "VRAM" T_SECT_SRAM "SRAM" T_SECT_OAM "OAM"

%type	<sectMod> sectmod
%type	<macroArg> macroargs

%type	<dsArgs> ds_args

%type	<forArgs> for_args

%token	T_Z80_ADC "adc" T_Z80_ADD "add" T_Z80_AND "and"
%token	T_Z80_BIT "bit" // There is no T_Z80_SET, only T_POP_SET
%token	T_Z80_CALL "call" T_Z80_CCF "ccf" T_Z80_CP "cp" T_Z80_CPL "cpl"
%token	T_Z80_DAA "daa" T_Z80_DEC "dec" T_Z80_DI "di"
%token	T_Z80_EI "ei"
%token	T_Z80_HALT "halt"
%token	T_Z80_INC "inc"
%token	T_Z80_JP "jp" T_Z80_JR "jr"
%token	T_Z80_LD "ld"
%token	T_Z80_LDI "ldi"
%token	T_Z80_LDD "ldd"
%token	T_Z80_LDH "ldh"
%token	T_Z80_NOP "nop"
%token	T_Z80_OR "or"
%token	T_Z80_POP "pop" T_Z80_PUSH "push"
%token	T_Z80_RES "res" T_Z80_RET "ret" T_Z80_RETI "reti" T_Z80_RST "rst"
%token	T_Z80_RL "rl" T_Z80_RLA "rla" T_Z80_RLC "rlc" T_Z80_RLCA "rlca"
%token	T_Z80_RR "rr" T_Z80_RRA "rra" T_Z80_RRC "rrc" T_Z80_RRCA "rrca"
%token	T_Z80_SBC "sbc" T_Z80_SCF "scf" T_Z80_STOP "stop"
%token	T_Z80_SLA "sla" T_Z80_SRA "sra" T_Z80_SRL "srl" T_Z80_SUB "sub"
%token	T_Z80_SWAP "swap"
%token	T_Z80_XOR "xor"

%token	T_TOKEN_A "a"
%token	T_TOKEN_B "b" T_TOKEN_C "c"
%token	T_TOKEN_D "d" T_TOKEN_E "e"
%token	T_TOKEN_H "h" T_TOKEN_L "l"
%token	T_MODE_AF "af" T_MODE_BC "bc" T_MODE_DE "de" T_MODE_SP "sp"
%token	T_MODE_HW_C "$ff00+c"
%token	T_MODE_HL "hl" T_MODE_HL_DEC "hld/hl-" T_MODE_HL_INC "hli/hl+"
%token	T_CC_NZ "nz" T_CC_Z "z" T_CC_NC "nc" // There is no T_CC_C, only T_TOKEN_C

%type	<nConstValue>	reg_r
%type	<nConstValue>	reg_ss
%type	<nConstValue>	reg_rr
%type	<nConstValue>	reg_tt
%type	<nConstValue>	ccode
%type	<sVal>		op_a_n
%type	<nConstValue>	op_a_r
%type	<sVal>		op_mem_ind
%type	<assertType>	assert_type

%token T_EOF 0 "end of file"
%start asmfile

%%

asmfile		: lines
;

/*
 * The lexer adds T_NEWLINE at the end of the file if one was not
 * already present, so we can rely on it to end a line.
 */
lines		: %empty
		| lines line
;

plain_directive	: label
		| label cpu_command
		| label macro
		| label directive
		| assignment_directive
;

line		: plain_directive T_NEWLINE
		| line_directive /* Directives that manage newlines themselves */
		| error T_NEWLINE { /* Continue parsing the next line on a syntax error */
			fstk_StopRept();
		}
;

/*
 * For "logistical" reasons, these directives must manage newlines themselves.
 * This is because we need to switch the lexer's mode *after* the newline has been read,
 * and to avoid causing some grammar conflicts (token reducing is finicky).
 * This is DEFINITELY one of the more FRAGILE parts of the codebase, handle with care.
 */
line_directive	: macrodef
		| rept
		| for
		| break
		| if
		/* It's important that all of these require being at line start for `skipIfBlock` */
		| elif
		| else
;

if		: T_POP_IF const T_NEWLINE {
			lexer_IncIFDepth();

			if ($2)
				lexer_RunIFBlock();
			else
				lexer_SetMode(LEXER_SKIP_TO_ELIF);
		}
;

elif		: T_POP_ELIF const T_NEWLINE {
			if (lexer_GetIFDepth() == 0)
				fatalerror("Found ELIF outside an IF construct\n");

			if (lexer_RanIFBlock()) {
				if (lexer_ReachedELSEBlock())
					fatalerror("Found ELIF after an ELSE block\n");

				lexer_SetMode(LEXER_SKIP_TO_ENDC);
			} else if ($2) {
				lexer_RunIFBlock();
			} else {
				lexer_SetMode(LEXER_SKIP_TO_ELIF);
			}
		}
;

else		: T_POP_ELSE T_NEWLINE {
			if (lexer_GetIFDepth() == 0)
				fatalerror("Found ELSE outside an IF construct\n");

			if (lexer_RanIFBlock()) {
				if (lexer_ReachedELSEBlock())
					fatalerror("Found ELSE after an ELSE block\n");

				lexer_SetMode(LEXER_SKIP_TO_ENDC);
			} else {
				lexer_RunIFBlock();
				lexer_ReachELSEBlock();
			}
		}
;

endc		: T_POP_ENDC {
			lexer_DecIFDepth();
		}
;

def_id		: T_OP_DEF {
			lexer_ToggleStringExpansion(false);
		} T_ID {
			lexer_ToggleStringExpansion(true);
			strcpy($$, $3);
		}
;

redef_id	: T_POP_REDEF {
			lexer_ToggleStringExpansion(false);
		} T_ID {
			lexer_ToggleStringExpansion(true);
			strcpy($$, $3);
		}
;

scoped_id	: T_ID | T_LOCAL_ID;
scoped_anon_id	: scoped_id | T_ANON;

label		: %empty
		| T_COLON {
			sym_AddAnonLabel();
		}
		| T_LOCAL_ID {
			sym_AddLocalLabel($1);
		}
		| T_LOCAL_ID T_COLON {
			sym_AddLocalLabel($1);
		}
		| T_LABEL T_COLON {
			sym_AddLabel($1);
		}
		| T_LOCAL_ID T_COLON T_COLON {
			sym_AddLocalLabel($1);
			sym_Export($1);
		}
		| T_LABEL T_COLON T_COLON {
			sym_AddLabel($1);
			sym_Export($1);
		}
;

macro		: T_ID {
			// Parsing 'macroargs' will restore the lexer's normal mode
			lexer_SetMode(LEXER_RAW);
		} macroargs {
			fstk_RunMacro($1, $3);
		}
;

macroargs	: %empty {
			$$ = macro_NewArgs();
		}
		| macroargs T_STRING {
			macro_AppendArg(&($$), strdup($2));
		}
;

/* These commands start with a T_LABEL. */
assignment_directive	: equ
		| set
		| rb
		| rw
		| rl
		| equs
;

directive	: include
		| endc
		| print
		| println
		| printf
		| printt
		| printv
		| printi
		| export
		| db
		| dw
		| dl
		| ds
		| section
		| rsreset
		| rsset
		| union
		| nextu
		| endu
		| incbin
		| charmap
		| newcharmap
		| setcharmap
		| pushc
		| popc
		| load
		| shift
		| fail
		| warn
		| assert
		| def_equ
		| def_set
		| def_rb
		| def_rw
		| def_rl
		| def_equs
		| redef_equs
		| purge
		| pops
		| pushs
		| popo
		| pusho
		| opt
		| align
;

trailing_comma	: %empty | T_COMMA
;

equ		: T_LABEL T_POP_EQU const	{ sym_AddEqu($1, $3); }
;

set_or_equal	: T_POP_SET | T_POP_EQUAL
;

set		: T_LABEL set_or_equal const	{ sym_AddSet($1, $3); }
;

equs		: T_LABEL T_POP_EQUS string	{ sym_AddString($1, $3); }
;

rb		: T_LABEL T_POP_RB rs_uconst {
			sym_AddEqu($1, sym_GetConstantValue("_RS"));
			sym_AddSet("_RS", sym_GetConstantValue("_RS") + $3);
		}
;

rw		: T_LABEL T_POP_RW rs_uconst {
			sym_AddEqu($1, sym_GetConstantValue("_RS"));
			sym_AddSet("_RS", sym_GetConstantValue("_RS") + 2 * $3);
		}
;

rl		: T_LABEL T_Z80_RL rs_uconst {
			sym_AddEqu($1, sym_GetConstantValue("_RS"));
			sym_AddSet("_RS", sym_GetConstantValue("_RS") + 4 * $3);
		}
;

align		: T_OP_ALIGN uconst {
			if ($2 > 16)
				error("Alignment must be between 0 and 16, not %u\n", $2);
			else
				sect_AlignPC($2, 0);
		}
		| T_OP_ALIGN uconst T_COMMA uconst {
			if ($2 > 16)
				error("Alignment must be between 0 and 16, not %u\n", $2);
			else if ($4 >= 1 << $2)
				error("Offset must be between 0 and %u, not %u\n",
					(1 << $2) - 1, $4);
			else
				sect_AlignPC($2, $4);
		}
;

opt		: T_POP_OPT {
			// Parsing 'opt_list' will restore the lexer's normal mode
			lexer_SetMode(LEXER_RAW);
		} opt_list
;

opt_list	: opt_list_entry
		| opt_list opt_list_entry
;

opt_list_entry	: T_STRING		{ opt_Parse($1); }
;

popo		: T_POP_POPO		{ opt_Pop(); }
;

pusho		: T_POP_PUSHO		{ opt_Push(); }
;

pops		: T_POP_POPS		{ out_PopSection(); }
;

pushs		: T_POP_PUSHS		{ out_PushSection(); }
;

fail		: T_POP_FAIL string	{ fatalerror("%s\n", $2); }
;

warn		: T_POP_WARN string	{ warning(WARNING_USER, "%s\n", $2); }
;

assert_type	: %empty		{ $$ = ASSERT_ERROR; }
		| T_POP_WARN T_COMMA	{ $$ = ASSERT_WARN; }
		| T_POP_FAIL T_COMMA	{ $$ = ASSERT_ERROR; }
		| T_POP_FATAL T_COMMA	{ $$ = ASSERT_FATAL; }
;

assert		: T_POP_ASSERT assert_type relocexpr
		{
			if (!rpn_isKnown(&$3)) {
				if (!out_CreateAssert($2, &$3, "",
						      sect_GetOutputOffset()))
					error("Assertion creation failed: %s\n",
						strerror(errno));
			} else if ($3.nVal == 0) {
				failAssert($2);
			}
			rpn_Free(&$3);
		}
		| T_POP_ASSERT assert_type relocexpr T_COMMA string
		{
			if (!rpn_isKnown(&$3)) {
				if (!out_CreateAssert($2, &$3, $5,
						      sect_GetOutputOffset()))
					error("Assertion creation failed: %s\n",
						strerror(errno));
			} else if ($3.nVal == 0) {
				failAssertMsg($2, $5);
			}
			rpn_Free(&$3);
		}
		| T_POP_STATIC_ASSERT assert_type const
		{
			if ($3 == 0)
				failAssert($2);
		}
		| T_POP_STATIC_ASSERT assert_type const T_COMMA string
		{
			if ($3 == 0)
				failAssertMsg($2, $5);
		}
;

shift		: T_POP_SHIFT		{ macro_ShiftCurrentArgs(1); }
		| T_POP_SHIFT const	{ macro_ShiftCurrentArgs($2); }
;

load		: T_POP_LOAD sectmod string T_COMMA sectiontype sectorg sectattrs {
			out_SetLoadSection($3, $5, $6, &$7, $2);
		}
		| T_POP_ENDL	{ out_EndLoadSection(); }
;

rept		: T_POP_REPT uconst T_NEWLINE {
			lexer_CaptureRept(&captureBody);
		} T_NEWLINE {
			fstk_RunRept($2, captureBody.lineNo, captureBody.body, captureBody.size);
		}
;

for		: T_POP_FOR {
			lexer_ToggleStringExpansion(false);
		} T_ID {
			lexer_ToggleStringExpansion(true);
		} T_COMMA for_args T_NEWLINE {
			lexer_CaptureRept(&captureBody);
		} T_NEWLINE {
			fstk_RunFor($3, $6.start, $6.stop, $6.step, captureBody.lineNo,
				    captureBody.body, captureBody.size);
		}

for_args	: const {
			$$.start = 0;
			$$.stop = $1;
			$$.step = 1;
		}
		| const T_COMMA const {
			$$.start = $1;
			$$.stop = $3;
			$$.step = 1;
		}
		| const T_COMMA const T_COMMA const {
			$$.start = $1;
			$$.stop = $3;
			$$.step = $5;
		}
;

break		: T_POP_BREAK T_NEWLINE {
			if (fstk_Break())
				lexer_SetMode(LEXER_SKIP_TO_ENDR);
		}
;

macrodef	: T_POP_MACRO {
			lexer_ToggleStringExpansion(false);
		} T_ID {
			lexer_ToggleStringExpansion(true);
		} T_NEWLINE {
			lexer_CaptureMacroBody(&captureBody);
		} T_NEWLINE {
			sym_AddMacro($3, captureBody.lineNo, captureBody.body, captureBody.size);
		}
		| T_LABEL T_COLON T_POP_MACRO T_NEWLINE {
			lexer_CaptureMacroBody(&captureBody);
		} T_NEWLINE {
			sym_AddMacro($1, captureBody.lineNo, captureBody.body, captureBody.size);
		}
;

rsset		: T_POP_RSSET uconst	{ sym_AddSet("_RS", $2); }
;

rsreset		: T_POP_RSRESET	{ sym_AddSet("_RS", 0); }
;

rs_uconst	: %empty {
			$$ = 1;
		}
		| uconst
;

union		: T_POP_UNION	{ sect_StartUnion(); }
;

nextu		: T_POP_NEXTU	{ sect_NextUnionMember(); }
;

endu		: T_POP_ENDU	{ sect_EndUnion(); }
;

ds		: T_POP_DS uconst	{ out_Skip($2, true); }
		| T_POP_DS uconst T_COMMA ds_args trailing_comma {
			out_RelBytes($2, $4.args, $4.nbArgs);
			freeDsArgList(&$4);
		}
;

ds_args		: reloc_8bit {
			initDsArgList(&$$);
			size_t i = nextDsArgListIndex(&$$);

			$$.args[i] = $1;
		}
		| ds_args T_COMMA reloc_8bit {
			size_t i = nextDsArgListIndex(&$1);

			$1.args[i] = $3;
			$$ = $1;
		}
;

db		: T_POP_DB	{ out_Skip(1, false); }
		| T_POP_DB constlist_8bit trailing_comma
;

dw		: T_POP_DW	{ out_Skip(2, false); }
		| T_POP_DW constlist_16bit trailing_comma
;

dl		: T_POP_DL	{ out_Skip(4, false); }
		| T_POP_DL constlist_32bit trailing_comma
;

def_equ		: def_id T_POP_EQU const {
			sym_AddEqu($1, $3);
		}
;

def_set		: def_id set_or_equal const {
			sym_AddSet($1, $3);
		}
		| redef_id set_or_equal const {
			sym_AddSet($1, $3);
		}
;

def_rb		: def_id T_POP_RB rs_uconst {
			sym_AddEqu($1, sym_GetConstantValue("_RS"));
			sym_AddSet("_RS", sym_GetConstantValue("_RS") + $3);
		}
;

def_rw		: def_id T_POP_RW rs_uconst {
			sym_AddEqu($1, sym_GetConstantValue("_RS"));
			sym_AddSet("_RS", sym_GetConstantValue("_RS") + 2 * $3);
		}
;

def_rl		: def_id T_Z80_RL rs_uconst {
			sym_AddEqu($1, sym_GetConstantValue("_RS"));
			sym_AddSet("_RS", sym_GetConstantValue("_RS") + 4 * $3);
		}
;

def_equs	: def_id T_POP_EQUS string {
			sym_AddString($1, $3);
		}
;

redef_equs	: redef_id T_POP_EQUS string {
			sym_RedefString($1, $3);
		}
;

purge		: T_POP_PURGE {
			lexer_ToggleStringExpansion(false);
		} purge_list trailing_comma {
			lexer_ToggleStringExpansion(true);
		}
;

purge_list	: purge_list_entry
		| purge_list T_COMMA purge_list_entry
;

purge_list_entry : scoped_id	{ sym_Purge($1); }
;

export		: T_POP_EXPORT export_list trailing_comma
;

export_list	: export_list_entry
		| export_list T_COMMA export_list_entry
;

export_list_entry : scoped_id	{ sym_Export($1); }
;

include		: T_POP_INCLUDE string {
			fstk_RunInclude($2);
			if (oFailedOnMissingInclude)
				YYACCEPT;
		}
;

incbin		: T_POP_INCBIN string {
			out_BinaryFile($2, 0);
			if (oFailedOnMissingInclude)
				YYACCEPT;
		}
		| T_POP_INCBIN string T_COMMA const {
			out_BinaryFile($2, $4);
			if (oFailedOnMissingInclude)
				YYACCEPT;
		}
		| T_POP_INCBIN string T_COMMA const T_COMMA const {
			out_BinaryFileSlice($2, $4, $6);
			if (oFailedOnMissingInclude)
				YYACCEPT;
		}
;

charmap		: T_POP_CHARMAP string T_COMMA const {
			if ($4 < INT8_MIN || $4 > UINT8_MAX)
				warning(WARNING_TRUNCATION, "Expression must be 8-bit\n");
			charmap_Add($2, (uint8_t)$4);
		}
;

newcharmap	: T_POP_NEWCHARMAP T_ID	{ charmap_New($2, NULL); }
		| T_POP_NEWCHARMAP T_ID T_COMMA T_ID	{ charmap_New($2, $4); }
;

setcharmap	: T_POP_SETCHARMAP T_ID	{ charmap_Set($2); }
;

pushc		: T_POP_PUSHC	{ charmap_Push(); }
;

popc		: T_POP_POPC	{ charmap_Pop(); }
;

print		: T_POP_PRINT print_exprs trailing_comma
;

println		: T_POP_PRINTLN {
			putchar('\n');
			fflush(stdout);
		}
		| T_POP_PRINTLN print_exprs trailing_comma {
			putchar('\n');
			fflush(stdout);
		}
;

print_exprs	: print_expr
		| print_exprs T_COMMA print_expr
;

print_expr	: const_no_str { printf("$%" PRIX32, $1); }
		| string { printf("%s", $1); }
;

printt		: T_POP_PRINTT string	{
			warning(WARNING_OBSOLETE, "`PRINTT` is deprecated; use `PRINT`\n");
			printf("%s", $2);
		}
;

printv		: T_POP_PRINTV const	{
			warning(WARNING_OBSOLETE, "`PRINTV` is deprecated; use `PRINT`\n");
			printf("$%" PRIX32, $2);
		}
;

printi		: T_POP_PRINTI const	{
			warning(WARNING_OBSOLETE, "`PRINTI` is deprecated; use `PRINT` with `STRFMT`\n");
			printf("%" PRId32, $2);
		}
;

printf		: T_POP_PRINTF const	{
			warning(WARNING_OBSOLETE, "`PRINTF` is deprecated; use `PRINT` with `STRFMT`\n");
			fix_Print($2);
		}
;

const_3bit	: const {
			int32_t value = $1;

			if ((value < 0) || (value > 7)) {
				error("Immediate value must be 3-bit\n");
				$$ = 0;
			} else {
				$$ = value & 0x7;
			}
		}
;

constlist_8bit	: constlist_8bit_entry
		| constlist_8bit T_COMMA constlist_8bit_entry
;

constlist_8bit_entry : reloc_8bit_no_str	{
			out_RelByte(&$1, 0);
		}
		| string {
			uint8_t *output = malloc(strlen($1)); /* Cannot be larger than that */
			int32_t length = charmap_Convert($1, output);

			out_AbsByteGroup(output, length);
			free(output);
		}
;

constlist_16bit : constlist_16bit_entry
		| constlist_16bit T_COMMA constlist_16bit_entry
;

constlist_16bit_entry : reloc_16bit_no_str	{
			out_RelWord(&$1, 0);
		}
		| string {
			uint8_t *output = malloc(strlen($1)); /* Cannot be larger than that */
			int32_t length = charmap_Convert($1, output);

			out_AbsWordGroup(output, length);
			free(output);
		}
;

constlist_32bit : constlist_32bit_entry
		| constlist_32bit T_COMMA constlist_32bit_entry
;

constlist_32bit_entry :relocexpr_no_str	{
			out_RelLong(&$1, 0);
		}
		| string {
			uint8_t *output = malloc(strlen($1)); /* Cannot be larger than that */
			int32_t length = charmap_Convert($1, output);

			out_AbsLongGroup(output, length);
			free(output);
		}
;

reloc_8bit	: relocexpr {
			if(rpn_isKnown(&$1)
			 && ($1.nVal < -128 || $1.nVal > 255))
				warning(WARNING_TRUNCATION, "Expression must be 8-bit\n");
			$$ = $1;
		}
;

reloc_8bit_no_str : relocexpr_no_str {
			if(rpn_isKnown(&$1)
			 && ($1.nVal < -128 || $1.nVal > 255))
				warning(WARNING_TRUNCATION, "Expression must be 8-bit\n");
			$$ = $1;
		}
;

reloc_16bit	: relocexpr {
			if (rpn_isKnown(&$1)
			 && ($1.nVal < -32768 || $1.nVal > 65535))
				warning(WARNING_TRUNCATION, "Expression must be 16-bit\n");
			$$ = $1;
		}
;

reloc_16bit_no_str : relocexpr_no_str {
			if (rpn_isKnown(&$1)
			 && ($1.nVal < -32768 || $1.nVal > 65535))
				warning(WARNING_TRUNCATION, "Expression must be 16-bit\n");
			$$ = $1;
		}
;


relocexpr	: relocexpr_no_str
		| string {
			uint8_t *output = malloc(strlen($1)); /* Cannot be longer than that */
			int32_t length = charmap_Convert($1, output);
			uint32_t r = str2int2(output, length);

			free(output);
			rpn_Number(&$$, r);
		}
;

relocexpr_no_str : scoped_anon_id	{ rpn_Symbol(&$$, $1); }
		| T_NUMBER	{ rpn_Number(&$$, $1); }
		| T_OP_LOGICNOT relocexpr %prec NEG {
			rpn_LOGNOT(&$$, &$2);
		}
		| relocexpr T_OP_LOGICOR relocexpr {
			rpn_BinaryOp(RPN_LOGOR, &$$, &$1, &$3);
		}
		| relocexpr T_OP_LOGICAND relocexpr {
			rpn_BinaryOp(RPN_LOGAND, &$$, &$1, &$3);
		}
		| relocexpr T_OP_LOGICEQU relocexpr {
			rpn_BinaryOp(RPN_LOGEQ, &$$, &$1, &$3);
		}
		| relocexpr T_OP_LOGICGT relocexpr {
			rpn_BinaryOp(RPN_LOGGT, &$$, &$1, &$3);
		}
		| relocexpr T_OP_LOGICLT relocexpr {
			rpn_BinaryOp(RPN_LOGLT, &$$, &$1, &$3);
		}
		| relocexpr T_OP_LOGICGE relocexpr {
			rpn_BinaryOp(RPN_LOGGE, &$$, &$1, &$3);
		}
		| relocexpr T_OP_LOGICLE relocexpr {
			rpn_BinaryOp(RPN_LOGLE, &$$, &$1, &$3);
		}
		| relocexpr T_OP_LOGICNE relocexpr {
			rpn_BinaryOp(RPN_LOGNE, &$$, &$1, &$3);
		}
		| relocexpr T_OP_ADD relocexpr {
			rpn_BinaryOp(RPN_ADD, &$$, &$1, &$3);
		}
		| relocexpr T_OP_SUB relocexpr {
			rpn_BinaryOp(RPN_SUB, &$$, &$1, &$3);
		}
		| relocexpr T_OP_XOR relocexpr {
			rpn_BinaryOp(RPN_XOR, &$$, &$1, &$3);
		}
		| relocexpr T_OP_OR relocexpr {
			rpn_BinaryOp(RPN_OR, &$$, &$1, &$3);
		}
		| relocexpr T_OP_AND relocexpr {
			rpn_BinaryOp(RPN_AND, &$$, &$1, &$3);
		}
		| relocexpr T_OP_SHL relocexpr {
			rpn_BinaryOp(RPN_SHL, &$$, &$1, &$3);
		}
		| relocexpr T_OP_SHR relocexpr {
			rpn_BinaryOp(RPN_SHR, &$$, &$1, &$3);
		}
		| relocexpr T_OP_MUL relocexpr {
			rpn_BinaryOp(RPN_MUL, &$$, &$1, &$3);
		}
		| relocexpr T_OP_DIV relocexpr {
			rpn_BinaryOp(RPN_DIV, &$$, &$1, &$3);
		}
		| relocexpr T_OP_MOD relocexpr {
			rpn_BinaryOp(RPN_MOD, &$$, &$1, &$3);
		}
		| relocexpr T_OP_EXP relocexpr {
			rpn_BinaryOp(RPN_EXP, &$$, &$1, &$3);
		}
		| T_OP_ADD relocexpr %prec NEG	{ $$ = $2; }
		| T_OP_SUB relocexpr %prec NEG	{ rpn_UNNEG(&$$, &$2); }
		| T_OP_NOT relocexpr %prec NEG	{ rpn_UNNOT(&$$, &$2); }
		| T_OP_HIGH T_LPAREN relocexpr T_RPAREN	{ rpn_HIGH(&$$, &$3); }
		| T_OP_LOW T_LPAREN relocexpr T_RPAREN	{ rpn_LOW(&$$, &$3); }
		| T_OP_ISCONST T_LPAREN relocexpr T_RPAREN{ rpn_ISCONST(&$$, &$3); }
		| T_OP_BANK T_LPAREN scoped_anon_id T_RPAREN {
			/* '@' is also a T_ID, it is handled here. */
			rpn_BankSymbol(&$$, $3);
		}
		| T_OP_BANK T_LPAREN string T_RPAREN	{ rpn_BankSection(&$$, $3); }
		| T_OP_DEF {
			lexer_ToggleStringExpansion(false);
		} T_LPAREN scoped_anon_id T_RPAREN {
			struct Symbol const *sym = sym_FindScopedSymbol($4);

			rpn_Number(&$$, !!sym);

			lexer_ToggleStringExpansion(true);
		}
		| T_OP_ROUND T_LPAREN const T_RPAREN {
			rpn_Number(&$$, fix_Round($3));
		}
		| T_OP_CEIL T_LPAREN const T_RPAREN {
			rpn_Number(&$$, fix_Ceil($3));
		}
		| T_OP_FLOOR T_LPAREN const T_RPAREN {
			rpn_Number(&$$, fix_Floor($3));
		}
		| T_OP_FDIV T_LPAREN const T_COMMA const T_RPAREN {
			rpn_Number(&$$, fix_Div($3, $5));
		}
		| T_OP_FMUL T_LPAREN const T_COMMA const T_RPAREN {
			rpn_Number(&$$, fix_Mul($3, $5));
		}
		| T_OP_POW T_LPAREN const T_COMMA const T_RPAREN {
			rpn_Number(&$$, fix_Pow($3, $5));
		}
		| T_OP_LOG T_LPAREN const T_COMMA const T_RPAREN {
			rpn_Number(&$$, fix_Log($3, $5));
		}
		| T_OP_SIN T_LPAREN const T_RPAREN {
			rpn_Number(&$$, fix_Sin($3));
		}
		| T_OP_COS T_LPAREN const T_RPAREN {
			rpn_Number(&$$, fix_Cos($3));
		}
		| T_OP_TAN T_LPAREN const T_RPAREN {
			rpn_Number(&$$, fix_Tan($3));
		}
		| T_OP_ASIN T_LPAREN const T_RPAREN {
			rpn_Number(&$$, fix_ASin($3));
		}
		| T_OP_ACOS T_LPAREN const T_RPAREN {
			rpn_Number(&$$, fix_ACos($3));
		}
		| T_OP_ATAN T_LPAREN const T_RPAREN {
			rpn_Number(&$$, fix_ATan($3));
		}
		| T_OP_ATAN2 T_LPAREN const T_COMMA const T_RPAREN {
			rpn_Number(&$$, fix_ATan2($3, $5));
		}
		| T_OP_STRCMP T_LPAREN string T_COMMA string T_RPAREN {
			rpn_Number(&$$, strcmp($3, $5));
		}
		| T_OP_STRIN T_LPAREN string T_COMMA string T_RPAREN {
			char *p = strstr($3, $5);

			rpn_Number(&$$, p ? p - $3 + 1 : 0);
		}
		| T_OP_STRRIN T_LPAREN string T_COMMA string T_RPAREN {
			char *p = strrstr($3, $5);

			rpn_Number(&$$, p ? p - $3 + 1 : 0);
		}
		| T_OP_STRLEN T_LPAREN string T_RPAREN {
			rpn_Number(&$$, strlenUTF8($3));
		}
		| T_LPAREN relocexpr T_RPAREN	{ $$ = $2; }
;

uconst		: const {
			$$ = $1;
			if ($$ < 0)
				fatalerror("Constant mustn't be negative: %d\n",
					   $1);
		}
;

const		: relocexpr {
			if (!rpn_isKnown(&$1)) {
				error("Expected constant expression: %s\n",
					$1.reason);
				$$ = 0;
			} else {
				$$ = $1.nVal;
			}
		}
;

const_no_str	: relocexpr_no_str {
			if (!rpn_isKnown(&$1)) {
				error("Expected constant expression: %s\n",
					$1.reason);
				$$ = 0;
			} else {
				$$ = $1.nVal;
			}
		}
;

string		: T_STRING
		| T_OP_STRSUB T_LPAREN string T_COMMA uconst T_COMMA uconst T_RPAREN {
			strsubUTF8($$, sizeof($$), $3, $5, $7);
		}
		| T_OP_STRCAT T_LPAREN T_RPAREN {
			$$[0] = '\0';
		}
		| T_OP_STRCAT T_LPAREN strcat_args T_RPAREN {
			strcpy($$, $3);
		}
		| T_OP_STRUPR T_LPAREN string T_RPAREN {
			upperstring($$, $3);
		}
		| T_OP_STRLWR T_LPAREN string T_RPAREN {
			lowerstring($$, $3);
		}
		| T_OP_STRRPL T_LPAREN string T_COMMA string T_COMMA string T_RPAREN {
			strrpl($$, sizeof($$), $3, $5, $7);
		}
		| T_OP_STRFMT T_LPAREN strfmt_args T_RPAREN {
			strfmt($$, sizeof($$), $3.format, $3.nbArgs, $3.args);
			freeStrFmtArgList(&$3);
		}
;

strcat_args	: string
		| strcat_args T_COMMA string {
			int ret = snprintf($$, sizeof($$), "%s%s", $1, $3);

			if (ret == -1)
				fatalerror("snprintf error in STRCAT: %s\n", strerror(errno));
			else if ((unsigned int)ret >= sizeof($$))
				warning(WARNING_LONG_STR, "STRCAT: String too long '%s%s'\n",
					$1, $3);
		}
;

strfmt_args	: string strfmt_va_args {
			$$.format = strdup($1);
			$$.capacity = $2.capacity;
			$$.nbArgs = $2.nbArgs;
			$$.args = $2.args;
		}
;

strfmt_va_args	: %empty {
			initStrFmtArgList(&$$);
		}
		| strfmt_va_args T_COMMA relocexpr_no_str {
			int32_t value;

			if (!rpn_isKnown(&$3)) {
				error("Expected constant expression: %s\n",
					$3.reason);
				value = 0;
			} else {
				value = $3.nVal;
			}

			size_t i = nextStrFmtArgListIndex(&$1);

			$1.args[i].number = value;
			$1.args[i].isNumeric = true;
			$$ = $1;
		}
		| strfmt_va_args T_COMMA string {
			size_t i = nextStrFmtArgListIndex(&$1);

			$1.args[i].string = strdup($3);
			$1.args[i].isNumeric = false;
			$$ = $1;
		}
;

section		: T_POP_SECTION sectmod string T_COMMA sectiontype sectorg sectattrs {
			out_NewSection($3, $5, $6, &$7, $2);
		}
;

sectmod		: %empty	{ $$ = SECTION_NORMAL; }
		| T_POP_UNION	{ $$ = SECTION_UNION; }
		| T_POP_FRAGMENT{ $$ = SECTION_FRAGMENT; }
;

sectiontype	: T_SECT_WRAM0	{ $$ = SECTTYPE_WRAM0; }
		| T_SECT_VRAM	{ $$ = SECTTYPE_VRAM; }
		| T_SECT_ROMX	{ $$ = SECTTYPE_ROMX; }
		| T_SECT_ROM0	{ $$ = SECTTYPE_ROM0; }
		| T_SECT_HRAM	{ $$ = SECTTYPE_HRAM; }
		| T_SECT_WRAMX	{ $$ = SECTTYPE_WRAMX; }
		| T_SECT_SRAM	{ $$ = SECTTYPE_SRAM; }
		| T_SECT_OAM	{ $$ = SECTTYPE_OAM; }
;

sectorg		: %empty { $$ = -1; }
		| T_LBRACK uconst T_RBRACK {
			if ($2 < 0 || $2 >= 0x10000) {
				error("Address $%x is not 16-bit\n", $2);
				$$ = -1;
			} else {
				$$ = $2;
			}
		}
;

sectattrs	: %empty {
			$$.alignment = 0;
			$$.alignOfs = 0;
			$$.bank = -1;
		}
		| sectattrs T_COMMA T_OP_ALIGN T_LBRACK uconst T_RBRACK {
			$$.alignment = $5;
		}
		| sectattrs T_COMMA T_OP_ALIGN T_LBRACK uconst T_COMMA uconst T_RBRACK {
			$$.alignment = $5;
			$$.alignOfs = $7;
		}
		| sectattrs T_COMMA T_OP_BANK T_LBRACK uconst T_RBRACK {
			/* We cannot check the validity of this now */
			$$.bank = $5;
		}
;


cpu_command	: z80_adc
		| z80_add
		| z80_and
		| z80_bit
		| z80_call
		| z80_ccf
		| z80_cp
		| z80_cpl
		| z80_daa
		| z80_dec
		| z80_di
		| z80_ei
		| z80_halt
		| z80_inc
		| z80_jp
		| z80_jr
		| z80_ld
		| z80_ldd
		| z80_ldi
		| z80_ldio
		| z80_nop
		| z80_or
		| z80_pop
		| z80_push
		| z80_res
		| z80_ret
		| z80_reti
		| z80_rl
		| z80_rla
		| z80_rlc
		| z80_rlca
		| z80_rr
		| z80_rra
		| z80_rrc
		| z80_rrca
		| z80_rst
		| z80_sbc
		| z80_scf
		| z80_set
		| z80_sla
		| z80_sra
		| z80_srl
		| z80_stop
		| z80_sub
		| z80_swap
		| z80_xor
;

z80_adc		: T_Z80_ADC op_a_n {
			out_AbsByte(0xCE);
			out_RelByte(&$2, 1);
		}
		| T_Z80_ADC op_a_r	{ out_AbsByte(0x88 | $2); }
;

z80_add		: T_Z80_ADD op_a_n {
			out_AbsByte(0xC6);
			out_RelByte(&$2, 1);
		}
		| T_Z80_ADD op_a_r	{ out_AbsByte(0x80 | $2); }
		| T_Z80_ADD T_MODE_HL T_COMMA reg_ss	{ out_AbsByte(0x09 | ($4 << 4)); }
		| T_Z80_ADD T_MODE_SP T_COMMA reloc_8bit {
			out_AbsByte(0xE8);
			out_RelByte(&$4, 1);
		}

;

z80_and		: T_Z80_AND op_a_n {
			out_AbsByte(0xE6);
			out_RelByte(&$2, 1);
		}
		| T_Z80_AND op_a_r	{ out_AbsByte(0xA0 | $2); }
;

z80_bit		: T_Z80_BIT const_3bit T_COMMA reg_r {
			out_AbsByte(0xCB);
			out_AbsByte(0x40 | ($2 << 3) | $4);
		}
;

z80_call	: T_Z80_CALL reloc_16bit {
			out_AbsByte(0xCD);
			out_RelWord(&$2, 1);
		}
		| T_Z80_CALL ccode T_COMMA reloc_16bit {
			out_AbsByte(0xC4 | ($2 << 3));
			out_RelWord(&$4, 1);
		}
;

z80_ccf		: T_Z80_CCF	{ out_AbsByte(0x3F); }
;

z80_cp		: T_Z80_CP op_a_n {
			out_AbsByte(0xFE);
			out_RelByte(&$2, 1);
		}
		| T_Z80_CP op_a_r	{ out_AbsByte(0xB8 | $2); }
;

z80_cpl		: T_Z80_CPL	{ out_AbsByte(0x2F); }
;

z80_daa		: T_Z80_DAA	{ out_AbsByte(0x27); }
;

z80_dec		: T_Z80_DEC reg_r	{ out_AbsByte(0x05 | ($2 << 3)); }
		| T_Z80_DEC reg_ss	{ out_AbsByte(0x0B | ($2 << 4)); }
;

z80_di		: T_Z80_DI	{ out_AbsByte(0xF3); }
;

z80_ei		: T_Z80_EI	{ out_AbsByte(0xFB); }
;

z80_halt	: T_Z80_HALT {
			out_AbsByte(0x76);
			if (haltnop)
				out_AbsByte(0x00);
		}
;

z80_inc		: T_Z80_INC reg_r	{ out_AbsByte(0x04 | ($2 << 3)); }
		| T_Z80_INC reg_ss	{ out_AbsByte(0x03 | ($2 << 4)); }
;

z80_jp		: T_Z80_JP reloc_16bit {
			out_AbsByte(0xC3);
			out_RelWord(&$2, 1);
		}
		| T_Z80_JP ccode T_COMMA reloc_16bit {
			out_AbsByte(0xC2 | ($2 << 3));
			out_RelWord(&$4, 1);
		}
		| T_Z80_JP T_MODE_HL {
			out_AbsByte(0xE9);
		}
;

z80_jr		: T_Z80_JR reloc_16bit {
			out_AbsByte(0x18);
			out_PCRelByte(&$2, 1);
		}
		| T_Z80_JR ccode T_COMMA reloc_16bit {
			out_AbsByte(0x20 | ($2 << 3));
			out_PCRelByte(&$4, 1);
		}
;

z80_ldi		: T_Z80_LDI T_LBRACK T_MODE_HL T_RBRACK T_COMMA T_MODE_A {
			out_AbsByte(0x02 | (2 << 4));
		}
		| T_Z80_LDI T_MODE_A T_COMMA T_LBRACK T_MODE_HL T_RBRACK {
			out_AbsByte(0x0A | (2 << 4));
		}
;

z80_ldd		: T_Z80_LDD T_LBRACK T_MODE_HL T_RBRACK T_COMMA T_MODE_A {
			out_AbsByte(0x02 | (3 << 4));
		}
		| T_Z80_LDD T_MODE_A T_COMMA T_LBRACK T_MODE_HL T_RBRACK {
			out_AbsByte(0x0A | (3 << 4));
		}
;

z80_ldio	: T_Z80_LDH T_MODE_A T_COMMA op_mem_ind {
			rpn_CheckHRAM(&$4, &$4);

			out_AbsByte(0xF0);
			out_RelByte(&$4, 1);
		}
		| T_Z80_LDH op_mem_ind T_COMMA T_MODE_A {
			rpn_CheckHRAM(&$2, &$2);

			out_AbsByte(0xE0);
			out_RelByte(&$2, 1);
		}
		| T_Z80_LDH T_MODE_A T_COMMA c_ind {
			out_AbsByte(0xF2);
		}
		| T_Z80_LDH c_ind T_COMMA T_MODE_A {
			out_AbsByte(0xE2);
		}
;

c_ind		: T_LBRACK T_MODE_C T_RBRACK
		| T_LBRACK T_MODE_HW_C T_RBRACK
;

z80_ld		: z80_ld_mem
		| z80_ld_cind
		| z80_ld_rr
		| z80_ld_ss
		| z80_ld_hl
		| z80_ld_sp
		| z80_ld_r
		| z80_ld_a
;

z80_ld_hl	: T_Z80_LD T_MODE_HL T_COMMA T_MODE_SP T_OP_ADD reloc_8bit {
			out_AbsByte(0xF8);
			out_RelByte(&$6, 1);
		}
		| T_Z80_LD T_MODE_HL T_COMMA reloc_16bit {
			out_AbsByte(0x01 | (REG_HL << 4));
			out_RelWord(&$4, 1);
		}
;

z80_ld_sp	: T_Z80_LD T_MODE_SP T_COMMA T_MODE_HL	{ out_AbsByte(0xF9); }
		| T_Z80_LD T_MODE_SP T_COMMA reloc_16bit {
			out_AbsByte(0x01 | (REG_SP << 4));
			out_RelWord(&$4, 1);
		}
;

z80_ld_mem	: T_Z80_LD op_mem_ind T_COMMA T_MODE_SP {
			out_AbsByte(0x08);
			out_RelWord(&$2, 1);
		}
		| T_Z80_LD op_mem_ind T_COMMA T_MODE_A {
			if (optimizeloads && rpn_isKnown(&$2)
			 && $2.nVal >= 0xFF00) {
				out_AbsByte(0xE0);
				out_AbsByte($2.nVal & 0xFF);
				rpn_Free(&$2);
			} else {
				out_AbsByte(0xEA);
				out_RelWord(&$2, 1);
			}
		}
;

z80_ld_cind	: T_Z80_LD c_ind T_COMMA T_MODE_A {
			out_AbsByte(0xE2);
		}
;

z80_ld_rr	: T_Z80_LD reg_rr T_COMMA T_MODE_A {
			out_AbsByte(0x02 | ($2 << 4));
		}
;

z80_ld_r	: T_Z80_LD reg_r T_COMMA reloc_8bit {
			out_AbsByte(0x06 | ($2 << 3));
			out_RelByte(&$4, 1);
		}
		| T_Z80_LD reg_r T_COMMA reg_r {
			if (($2 == REG_HL_IND) && ($4 == REG_HL_IND))
				error("LD [HL],[HL] not a valid instruction\n");
			else
				out_AbsByte(0x40 | ($2 << 3) | $4);
		}
;

z80_ld_a	: T_Z80_LD reg_r T_COMMA c_ind {
			if ($2 == REG_A)
				out_AbsByte(0xF2);
			else
				error("Destination operand must be A\n");
		}
		| T_Z80_LD reg_r T_COMMA reg_rr {
			if ($2 == REG_A)
				out_AbsByte(0x0A | ($4 << 4));
			else
				error("Destination operand must be A\n");
		}
		| T_Z80_LD reg_r T_COMMA op_mem_ind {
			if ($2 == REG_A) {
				if (optimizeloads && rpn_isKnown(&$4)
				 && $4.nVal >= 0xFF00) {
					out_AbsByte(0xF0);
					out_AbsByte($4.nVal & 0xFF);
					rpn_Free(&$4);
				} else {
					out_AbsByte(0xFA);
					out_RelWord(&$4, 1);
				}
			} else {
				error("Destination operand must be A\n");
				rpn_Free(&$4);
			}
		}
;

z80_ld_ss	: T_Z80_LD T_MODE_BC T_COMMA reloc_16bit {
			out_AbsByte(0x01 | (REG_BC << 4));
			out_RelWord(&$4, 1);
		}
		| T_Z80_LD T_MODE_DE T_COMMA reloc_16bit {
			out_AbsByte(0x01 | (REG_DE << 4));
			out_RelWord(&$4, 1);
		}
		/*
		 * HL is taken care of in z80_ld_hl
		 * SP is taken care of in z80_ld_sp
		 */
;

z80_nop		: T_Z80_NOP	{ out_AbsByte(0x00); }
;

z80_or		: T_Z80_OR op_a_n {
			out_AbsByte(0xF6);
			out_RelByte(&$2, 1);
		}
		| T_Z80_OR op_a_r	{ out_AbsByte(0xB0 | $2); }
;

z80_pop		: T_Z80_POP reg_tt	{ out_AbsByte(0xC1 | ($2 << 4)); }
;

z80_push	: T_Z80_PUSH reg_tt	{ out_AbsByte(0xC5 | ($2 << 4)); }
;

z80_res		: T_Z80_RES const_3bit T_COMMA reg_r {
			out_AbsByte(0xCB);
			out_AbsByte(0x80 | ($2 << 3) | $4);
		}
;

z80_ret		: T_Z80_RET	{ out_AbsByte(0xC9);
		}
		| T_Z80_RET ccode	{ out_AbsByte(0xC0 | ($2 << 3)); }
;

z80_reti	: T_Z80_RETI	{ out_AbsByte(0xD9); }
;

z80_rl		: T_Z80_RL reg_r {
			out_AbsByte(0xCB);
			out_AbsByte(0x10 | $2);
		}
;

z80_rla		: T_Z80_RLA	{ out_AbsByte(0x17); }
;

z80_rlc		: T_Z80_RLC reg_r {
			out_AbsByte(0xCB);
			out_AbsByte(0x00 | $2);
		}
;

z80_rlca	: T_Z80_RLCA	{ out_AbsByte(0x07); }
;

z80_rr		: T_Z80_RR reg_r {
			out_AbsByte(0xCB);
			out_AbsByte(0x18 | $2);
		}
;

z80_rra		: T_Z80_RRA	{ out_AbsByte(0x1F); }
;

z80_rrc		: T_Z80_RRC reg_r {
			out_AbsByte(0xCB);
			out_AbsByte(0x08 | $2);
		}
;

z80_rrca	: T_Z80_RRCA	{ out_AbsByte(0x0F); }
;

z80_rst		: T_Z80_RST reloc_8bit {
			rpn_CheckRST(&$2, &$2);
			if (!rpn_isKnown(&$2))
				out_RelByte(&$2, 0);
			else
				out_AbsByte(0xC7 | $2.nVal);
			rpn_Free(&$2);
		}
;

z80_sbc		: T_Z80_SBC op_a_n {
			out_AbsByte(0xDE);
			out_RelByte(&$2, 1);
		}
		| T_Z80_SBC op_a_r	{ out_AbsByte(0x98 | $2); }
;

z80_scf		: T_Z80_SCF	{ out_AbsByte(0x37); }
;

z80_set		: T_POP_SET const_3bit T_COMMA reg_r {
			out_AbsByte(0xCB);
			out_AbsByte(0xC0 | ($2 << 3) | $4);
		}
;

z80_sla		: T_Z80_SLA reg_r {
			out_AbsByte(0xCB);
			out_AbsByte(0x20 | $2);
		}
;

z80_sra		: T_Z80_SRA reg_r {
			out_AbsByte(0xCB);
			out_AbsByte(0x28 | $2);
		}
;

z80_srl		: T_Z80_SRL reg_r {
			out_AbsByte(0xCB);
			out_AbsByte(0x38 | $2);
		}
;

z80_stop	: T_Z80_STOP {
			out_AbsByte(0x10);
			out_AbsByte(0x00);
		}
		| T_Z80_STOP reloc_8bit {
			out_AbsByte(0x10);
			out_RelByte(&$2, 1);
		}
;

z80_sub		: T_Z80_SUB op_a_n {
			out_AbsByte(0xD6);
			out_RelByte(&$2, 1);
		}
		| T_Z80_SUB op_a_r	{ out_AbsByte(0x90 | $2);
		}
;

z80_swap	: T_Z80_SWAP reg_r {
			out_AbsByte(0xCB);
			out_AbsByte(0x30 | $2);
		}
;

z80_xor		: T_Z80_XOR op_a_n {
			out_AbsByte(0xEE);
			out_RelByte(&$2, 1);
		}
		| T_Z80_XOR op_a_r	{ out_AbsByte(0xA8 | $2); }
;

op_mem_ind	: T_LBRACK reloc_16bit T_RBRACK	{ $$ = $2; }
;

op_a_r		: reg_r
		| T_MODE_A T_COMMA reg_r	{ $$ = $3; }
;

op_a_n		: reloc_8bit
		| T_MODE_A T_COMMA reloc_8bit	{ $$ = $3; }
;

T_MODE_A	: T_TOKEN_A
		| T_OP_HIGH T_LPAREN T_MODE_AF T_RPAREN
;

T_MODE_B	: T_TOKEN_B
		| T_OP_HIGH T_LPAREN T_MODE_BC T_RPAREN
;

T_MODE_C	: T_TOKEN_C
		| T_OP_LOW T_LPAREN T_MODE_BC T_RPAREN
;

T_MODE_D	: T_TOKEN_D
		| T_OP_HIGH T_LPAREN T_MODE_DE T_RPAREN
;

T_MODE_E	: T_TOKEN_E
		| T_OP_LOW T_LPAREN T_MODE_DE T_RPAREN
;

T_MODE_H	: T_TOKEN_H
		| T_OP_HIGH T_LPAREN T_MODE_HL T_RPAREN
;

T_MODE_L	: T_TOKEN_L
		| T_OP_LOW T_LPAREN T_MODE_HL T_RPAREN
;

ccode		: T_CC_NZ		{ $$ = CC_NZ; }
		| T_CC_Z		{ $$ = CC_Z; }
		| T_CC_NC		{ $$ = CC_NC; }
		| T_TOKEN_C		{ $$ = CC_C; }
;

reg_r		: T_MODE_B		{ $$ = REG_B; }
		| T_MODE_C		{ $$ = REG_C; }
		| T_MODE_D		{ $$ = REG_D; }
		| T_MODE_E		{ $$ = REG_E; }
		| T_MODE_H		{ $$ = REG_H; }
		| T_MODE_L		{ $$ = REG_L; }
		| T_LBRACK T_MODE_HL T_RBRACK	{ $$ = REG_HL_IND; }
		| T_MODE_A		{ $$ = REG_A; }
;

reg_tt		: T_MODE_BC		{ $$ = REG_BC; }
		| T_MODE_DE		{ $$ = REG_DE; }
		| T_MODE_HL		{ $$ = REG_HL; }
		| T_MODE_AF		{ $$ = REG_AF; }
;

reg_ss		: T_MODE_BC		{ $$ = REG_BC; }
		| T_MODE_DE		{ $$ = REG_DE; }
		| T_MODE_HL		{ $$ = REG_HL; }
		| T_MODE_SP		{ $$ = REG_SP; }
;

reg_rr		: T_LBRACK T_MODE_BC T_RBRACK	{ $$ = REG_BC_IND; }
		| T_LBRACK T_MODE_DE T_RBRACK	{ $$ = REG_DE_IND; }
		| hl_ind_inc		{ $$ = REG_HL_INDINC; }
		| hl_ind_dec		{ $$ = REG_HL_INDDEC; }
;

hl_ind_inc	: T_LBRACK T_MODE_HL_INC T_RBRACK
		| T_LBRACK T_MODE_HL T_OP_ADD T_RBRACK
;

hl_ind_dec	: T_LBRACK T_MODE_HL_DEC T_RBRACK
		| T_LBRACK T_MODE_HL T_OP_SUB T_RBRACK
;

%%
