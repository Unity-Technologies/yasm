/* $IdPath$
 * YAPP lexer
 *
 *  Copyright (C) 2001  Michael Urman
 *
 *  This file is part of YASM.
 *
 *  YASM is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  YASM is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */
%{
#include "util.h"
/*@unused@*/ RCSID("$IdPath$");

#include <errno.h>

#include "errwarn.h"

#include "src/preprocs/yapp/yapp-preproc.h"
#include "src/preprocs/yapp/yapp-token.h"


#define yylval	yapp_preproc_lval

/* starting size of string buffer */
#define STRBUF_ALLOC_SIZE	128

/* string buffer used when parsing strings/character constants */
static char *strbuf = (char *)NULL;

/* length of strbuf (including terminating NULL character) */
static size_t strbuf_size = 0;

/* include file mumbo jumbo */
static SLIST_HEAD(include_head, include_s) includes_head;
struct include_s {
    SLIST_ENTRY(include_s) next;
    YY_BUFFER_STATE include_state;
    char *filename;
    int line_number;
};
typedef struct include_s include;

char *current_file;
int line_number;

%}
%option noyywrap
%option nounput
%option case-insensitive
%option prefix="yapp_preproc_"
%option outfile="lex.yy.c"

%x D
%x incl
%x line
%x inhibit

DIGIT    [0-9]
BINDIGIT [01]
OCTDIGIT [0-7]
HEXDIGIT [0-9a-f]
WS       [ \t]
DIR	 %[ \t]*

%%

    /* standard decimal integer */
{DIGIT}+ {
    yylval.int_str_val.val = strtoul(yytext, (char **)NULL, 10);
    yylval.int_str_val.str = yytext;
    return INTNUM;
}

    /* 10010011b - binary number */
{BINDIGIT}+b {
    yylval.int_str_val.val = strtoul(yytext, (char **)NULL, 2);
    yylval.int_str_val.str = yytext;
    return INTNUM;
}

    /* 777q - octal number */
{OCTDIGIT}+q {
    yylval.int_str_val.val = strtoul(yytext, (char **)NULL, 8);
    yylval.int_str_val.str = yytext;
    return INTNUM;
}

    /* 0AAh form of hexidecimal number */
0{HEXDIGIT}+h {
    yylval.int_str_val.val = strtoul(yytext+1, (char **)NULL, 16);
    yylval.int_str_val.str = yytext;
    return INTNUM;
}

    /* $0AA and 0xAA forms of hexidecimal number */
(\$0|0x){HEXDIGIT}+ {
    yylval.int_str_val.val = strtoul(yytext+2, (char **)NULL, 16);
    yylval.int_str_val.str = yytext;
    return INTNUM;
}

    /* floating point value */
{DIGIT}+\.{DIGIT}*(e[-+]?{DIGIT}+)? {
    yylval.double_str_val.val = strtod(yytext, (char **)NULL);
    yylval.double_str_val.str = yytext;
    return FLTNUM;
}

    /* string/character constant values */
["']	{
    int inch, count;
    char endch = yytext[0];

    strbuf = malloc(STRBUF_ALLOC_SIZE);
    if(!strbuf)
	Fatal(FATAL_NOMEM);

    strbuf_size = STRBUF_ALLOC_SIZE;
    inch = input();
    count = 0;
    while(inch != EOF && inch != endch && inch != '\n') {
	strbuf[count++] = inch;
	if(count >= strbuf_size) {
	    strbuf = realloc(strbuf, strbuf_size + STRBUF_ALLOC_SIZE);
	    if(!strbuf)
		Fatal(FATAL_NOMEM);
	    strbuf_size += STRBUF_ALLOC_SIZE;
	}
	inch = input();
    }

    if(inch == '\n')
	Error(_("unterminated string"));
    else if(inch == EOF)
	Error(_("unexpected end of file in string"));

    strbuf[count] = '\0';

    yylval.str_val = strbuf;
    return STRING;
}

    /* identifiers */
\.\.[a-z0-9_$#@~.?]+ |
\.[a-z0-9_$#@~?][a-z0-9_$#@~.?]* | 
[a-z_?][a-z0-9_$#@~.?]* {
    yylval.str_val = xstrdup(yytext);
    return IDENT;
}

    /* includes - based on flex manual handling of include files */
<inhibit>{DIR}include[^\n]* ;
{DIR}include  BEGIN(incl);
    /* note the " handling here is a hack that doesn't accept useful
     * things (like spaces, or quotes).  fix it later */
<incl>[ \t"]*	/* eat whitespace */
<incl>[^ \t\n"]* { /* have the filename */
    include *inc;
    FILE *incfile;
    inc = xmalloc(sizeof(include));
    inc->include_state = YY_CURRENT_BUFFER;

    /* FIXME: handle includes that aren't relative */
    incfile = fopen (yytext, "r");
    if(!incfile) {
	Error(_("include file `%s': %s"),
		yytext, strerror(errno));
	free(inc);
    }
    else {
	yyin = incfile;
	inc->filename = current_file;
	inc->line_number = line_number;
	SLIST_INSERT_HEAD(&includes_head, inc, next);

	line_number = 1;
	current_file = xstrdup(yytext);
	BEGIN(INITIAL);
	yy_switch_to_buffer(yy_create_buffer(yyin, YY_BUF_SIZE));
    }
    return INCLUDE;
}

    /* end includes - note that it's not in <incl> at the time */
<<EOF>> {
    if(SLIST_EMPTY(&includes_head)) {
	yyterminate();
    }
    else {
	include *inc;
	inc = SLIST_FIRST(&includes_head);
	yy_delete_buffer (YY_CURRENT_BUFFER);
	yy_switch_to_buffer (inc->include_state);
	free(current_file);
	current_file = inc->filename;
	line_number = inc->line_number + 1;
	SLIST_REMOVE_HEAD(&includes_head, next);
	free(inc);

	BEGIN(incl);
	return INCLUDE;
    }
}

<incl>["]{WS}*\n    BEGIN(INITIAL);


    /* directive: % directive [args] */
<inhibit>{DIR}clear[^\n]    ;
{DIR}clear    return CLEAR;

<inhibit>{DIR}line[^\n]    ;
{DIR}line     BEGIN(line);
<line>{DIGIT}+	    line_number = strtoul(yytext, (char **)NULL, 10);
<line>{DIGIT}+{WS}*\n	{
    line_number = strtoul(yytext, (char **)NULL, 10);
    BEGIN(INITIAL);
    return LINE;
}
<line>{WS}+["]	    ;	/* eat space before file */
<line>[^ \t\n"]*    { /* have the filename */
    free(current_file);
    current_file = xstrdup(yytext);
}
<line>["]{WS}*\n    {
    BEGIN(INITIAL);
    return LINE;
}

{DIR}define   return DEFINE;
{DIR}undef    return UNDEF;
{DIR}assign   return ASSIGN;
{DIR}macro    return MACRO;
{DIR}endmacro return ENDMACRO;
{DIR}rotate   return ROTATE;
<inhibit>{DIR}define[^\n]*	;
<inhibit>{DIR}undef[^\n]*	;
<inhibit>{DIR}assign[^\n]*	;
<inhibit>{DIR}macro[^\n]*	;
<inhibit>{DIR}endmacro[^\n]*	;
<inhibit>{DIR}rotate[^\n]*	;

    /* preprocessor loops */
{DIR}rep      return REP;
{DIR}exitrep  return EXITREP;
{DIR}endrep   return ENDREP;
<inhibit>{DIR}rep[^\n]*	;
<inhibit>{DIR}exitrep[^\n]*	;
<inhibit>{DIR}endrep[^\n]*	;

{DIR}if       return IF;
{DIR}elif     return ELIF;
{DIR}else     return ELSE;
{DIR}endif    return ENDIF;
<inhibit>{DIR}if       { BEGIN(INITIAL); return IF; }
<inhibit>{DIR}elif     { BEGIN(INITIAL); return ELIF; }
<inhibit>{DIR}else     { BEGIN(INITIAL); return ELSE; }
<inhibit>{DIR}endif    { BEGIN(INITIAL); return ENDIF; }

    /* test defines */
{DIR}ifdef    return IFDEF;
{DIR}elifdef  return ELIFDEF;
{DIR}ifndef   return IFNDEF;
{DIR}elifndef return ELIFNDEF;
<inhibit>{DIR}ifdef    { BEGIN(INITIAL); return IFDEF; }
<inhibit>{DIR}elifdef  { BEGIN(INITIAL); return ELIFDEF; }
<inhibit>{DIR}ifndef   { BEGIN(INITIAL); return IFNDEF; }
<inhibit>{DIR}elifndef { BEGIN(INITIAL); return ELIFNDEF; }

    /* test context stack */
{DIR}ifctx    return IFCTX;
{DIR}elifctx  return ELIFCTX;
<inhibit>{DIR}ifctx    { BEGIN(INITIAL); return IFCTX; }
<inhibit>{DIR}elifctx  { BEGIN(INITIAL); return ELIFCTX; }

    /* test exact identity */
{DIR}ifidn    return IFIDN;
{DIR}elifidn  return ELIFIDN;
{DIR}ifidni   return IFIDNI;
{DIR}elifidni return ELIFIDNI;
<inhibit>{DIR}ifidn    { BEGIN(INITIAL); return IFIDN; }
<inhibit>{DIR}elifidn  { BEGIN(INITIAL); return ELIFIDN; }
<inhibit>{DIR}ifidni   { BEGIN(INITIAL); return IFIDNI; }
<inhibit>{DIR}elifidni { BEGIN(INITIAL); return ELIFIDNI; }

    /* test token types */
{DIR}ifid     return IFID;
{DIR}elifid   return ELIFID;
{DIR}ifnum    return IFNUM;
{DIR}elifnum  return ELIFNUM;
{DIR}ifstr    return IFSTR;
{DIR}elifstr  return ELIFSTR;
<inhibit>{DIR}ifid     { BEGIN(INITIAL); return IFID; }
<inhibit>{DIR}elifid   { BEGIN(INITIAL); return ELIFID; }
<inhibit>{DIR}ifnum    { BEGIN(INITIAL); return IFNUM; }
<inhibit>{DIR}elifnum  { BEGIN(INITIAL); return ELIFNUM; }
<inhibit>{DIR}ifstr    { BEGIN(INITIAL); return IFSTR; }
<inhibit>{DIR}elifstr  { BEGIN(INITIAL); return ELIFSTR; }

    /* error reporting */
<inhibit>{DIR}error[^\n]*  ;
{DIR}error[ ]+.*    { yylval.str_val = yytext; return ERROR; }

    /* context stack management */
{DIR}push     return PUSH;
{DIR}pop      return POP;
{DIR}repl     return REPL;
<inhibit>{DIR}push[^\n]*  ;
<inhibit>{DIR}pop[^\n]*  ;
<inhibit>{DIR}repl[^\n]*  ;

<inhibit>[^%\n]*\n { line_number++; return '\n'; }

;.*\n	{ line_number++; return '\n'; }

{WS}+	{ yylval.str_val = yytext; return WHITESPACE; }

{WS}*\n	{ line_number++; return '\n'; }


[][+*/,()-] { return yytext[0]; }

<inhibit>.  {
    Warning(_("Unhandled character in <inhibit> `%s'"), conv_unprint(yytext[0]));
}

.	{
    Warning(_("ignoring unrecognized character `%s'"),
	    conv_unprint(yytext[0]));
}

%%

void
yapp_lex_initialize(FILE *f)
{
    SLIST_INIT(&includes_head);
    yyin = f;
}

void set_inhibit(void)
{
    BEGIN(inhibit);
}