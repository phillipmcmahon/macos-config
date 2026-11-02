#!/usr/bin/env bash
# mkrand  - bash function to generate random string, with some options
# (C) 2018-2025 - F-Hauri.ch
# Licensed by GNU GENERAL PUBLIC LICENSE Version 3

(( ( BASH_VERSINFO[0] > 5 ) | ( BASH_VERSINFO[0] == 5 & BASH_VERSINFO[1] >= 1 ) )) ||
    { echo >&2 "Bash version >= 5.1 required ($BASH_VERSION)"; return 1;}

mkrand () { 
    local -i _slen=32 _p _sepmask=0x888800 _NMode=10 _XMode=16 _AMode=64 _mode=_XMode \
	  _EMode=93 _rand; local _str _part _opt _sep=- _result OPT{IND,ARG,ERR} _refstr
    while getopts "haedxl:m:s:v:" _opt; do
	case $_opt in
	    h) cat <<-EOUsage
		Usage: $FUNCNAME [-h] [-a|-d|-e|-x] [-l len] [-s sep] [-m int] [-v varname]
		  -h       Show this.
		  -a	   Alternative set of 64 chars ( alpha numerics + '%' + '#' )
		  -d	   Digits only
		  -e       Extended set, hold 93 printable ascii characters: x21'!' to x7e'~'
		  -x	   Hexadecimal characters (default)
		  -l int   Length of generated srting (without separators)
		  -m int   Mask for separators (default 0x888800: 1<<23|1<<19|1<<15|1<<11)
		  -s sep   String to be used as separator (default "-")
		  -v name  Variable name to be populated instead of print to STDOUT
		Without argument ${FUNCNAME} will print UUID like 32 hexadecimal string.
		  513ee11e-d6cc-b7b1-8fd9-3462675e93d5
		With \`-m 0\` or \`-s ''\`, noseparator will by added.
		Mask for separator is a binary value, used to determine where to insert dash.
		Note: switches -a, -d, -e and -x are mutualy exclusive.
		To generate an alpha numeric string of 30 characters, separated every 5 char:
		  mkrand -al30 -m0x1084210 -s' '
		  3PiQo 9RXFn NIi#7 %spWG HREhx wNamf
		A string of 7 bunch of 6 digits, separated by a spaced dash:
		  mkrand -d -l 42 -m 0x820820820 -s ' - '
		  941908 - 240445 - 797528 - 631958 - 635053 - 160422 - 927104
EOUsage
	       return;;
	    a) _mode=$_AMode ;;
	    d) _mode=$_NMode ;;
	    e) _mode=$_EMode ;;
	    x) _mode=$_XMode ;;
	    l) _slen=$OPTARG ;;
	    m) _sepmask=$OPTARG ;;
	    s) _sep="$OPTARG" ;;
	    v) local -n _result=$OPTARG ;;
	    *) echo >&2 "Wrong argument.";return 1 ;;
	esac
    done
    _result=""
    case $_mode in
	$_XMode )
	    for ((_p=_slen; _p>0; _p-=8)) ;do
		printf -v _part '%08x' $SRANDOM
		_result+=${_part}
	    done
	    ;;
	$_NMode )
	    for ((_p=_slen; _p>0; _p-=9)) ;do
		for ((;_part=SRANDOM,_part>= 4000000000;)) {
		    : #Drop RANDOMs between 4'000'000'000 and 4'294'967'295
		}
		printf -v _part '%010d' $_part
		_result+=${_part:1}
	    done
	    ;;
	$_AMode )
	    printf -v _refstr "%s" {0..9} {a..z} {A..Z} \# %
	    for (( _p=_slen; _part=SRANDOM, _p>0 ; _p-=5 )); do
		for (( _i=0; _i<30; _i+=6 )); do
		    _result+=${_refstr:(_part>>_i)&63:1}
		done
	    done
	    ;;
	$_EMode )
	    printf -v _refstr '\\x%X' {33..126}
	    printf -v _refstr '%b' "$_refstr"
	    for (( _p=_slen; _part=SRANDOM, _p>0 ; 1 )); do
		for (( _i=0; _i<28; _i+=7 )); do
	            _rand="(_part>>_i)&127"
		    if ((_rand < 94 )); then
			_result+=${_refstr:_rand:1}
			_p+=-1
		    fi
		done
	    done
	    ;;
    esac
    _result=${_result::_slen}
    [[ $_sep ]] && (( _sepmask )) &&
	for ((_p=_slen;_p>1;_p--)) ;do
            (( ( _sepmask >> ( _slen - _p )) & 1 )) &&
		_result=${_result::_p-1}${_sep}${_result: _p-1}
	done
    [[ ${_result@A} != _result=* ]] || echo "$_result"
}
