"
" Copyright (C) 2012-2016 Adrian Perez de Castro <aperez@igalia.com>
" Copyright (C) 2005 Adrian Perez de Castro <the.lightman@gmail.com>
"
" Distributed under terms of the MIT license.
"

if exists('g:template_autoload_loaded')
	finish
endif
let g:template_autoload_loaded = 1

let s:saved_cpoptions = &cpoptions
set cpoptions&vim


function! s:Debug(mesg) abort
	if g:templates_debug
		echom(a:mesg)
	endif
endfunction

" normalize the path
" replace the windows path sep \ with /
function! s:NormalizePath(path) abort
	return substitute(a:path, "\\", "/", "g")
endfunction

" Returns a string containing the path of the parent directory of the given
" path. Works like dirname(3). It also simplifies the given path.
function! s:DirName(path) abort
	let l:tmp = s:NormalizePath(a:path)
	return substitute(l:tmp, "[^/][^/]*/*$", "", "")
endfunction

" Directory containing built-in templates
let s:default_template_dir = s:DirName(s:DirName(expand('<sfile>'))) . 'templates'

" Find the target template in windows
"
" In windows while we clone the symbol link from github
" it will turn to normal file, so we use this function
" to figure out the destination file
function! s:TFindLink(path, template) abort
	if !filereadable(a:path . a:template)
		return a:template
	endif

	let l:content = readfile(a:path . a:template, 'b')
	if len(l:content) != 1
		return a:template
	endif

	if filereadable(a:path . l:content[0])
		return s:TFindLink(a:path, l:content[0])
	else
		return a:template
	endif
endfunction

" Translate a template file name into a regular expression to test for matching
" against a given filename. As of writing this behavior is something like this:
" (with a g:templates_name_prefix set as 'template.')
"
" template.py -> ^.*py$
"
" template.test.py -> ^.*test.py$
"
function! s:TemplateToRegex(template, prefix) abort
	let l:template_base_name = fnamemodify(a:template, ':t')
	let l:template_glob = strpart(l:template_base_name, len(a:prefix))

	" Translate the template's glob into a normal regular expression
	let l:in_escape_mode = 0
	let l:template_regex = ''
	for l:c in split(l:template_glob, '\zs')
		if l:in_escape_mode == 1
			if l:c == '\'
				let l:template_regex = l:template_regex . '\\'
			else
				let l:template_regex = l:template_regex . l:c
			endif

			let l:in_escape_mode = 0
		else
			if l:c == '\'
				let l:in_escape_mode = 1
			else
				let l:tr_index = index(g:templates_tr_in, l:c)
				if l:tr_index != -1
					let l:template_regex = l:template_regex . g:templates_tr_out[l:tr_index]
				else
					let l:template_regex = l:template_regex . l:c
				endif
			endif
		endif
	endfor

	if g:templates_fuzzy_start
		return l:template_regex . '$'
	else
		return '^' . l:template_regex . '$'
	endif

endfunction

" Given a template and filename, return a score on how well the template matches
" the given filename.  If the template does not match the file name at all,
" return 0
function! s:TemplateBaseNameTest(template, prefix, filename) abort
	let l:tregex = s:TemplateToRegex(a:template, a:prefix)

	" Ensure that we got a valid regex
	if empty(l:tregex)
		return 0
	endif

	" For now only use the base of the filename.. this may change later
	" *Note* we also have to be careful because a:filename may also be the passed
	" in text from TLoadCmd...
	let l:filename_chopped = fnamemodify(a:filename, ':t')

	" Check for a match
	let l:regex_result = match(l:filename_chopped, l:tregex)
	if l:regex_result != -1
		" For a match return a score based on the regex length
		return len(l:tregex)
	else
		" No match
		return 0
	endif
endfunction

" Returns the most specific / highest scored template file found in the given
" path.  Template files are found by using a glob operation on the current path
" and the setting of g:templates_name_prefix. If no template is found in the
" given directory, return an empty string
function! s:TDirectorySearch(path, template_prefix, file_name) abort
	let l:picked_template = ''
	let l:picked_template_score = 0

	" Use find if possible as it will also get hidden files on nix systems. Use
	" builtin glob as a fallback
	if executable('find') && !has('win32') && !has('win64')
		let l:find_cmd = '`find -L ' . shellescape(a:path) . ' -maxdepth 1 -type f -name ' . shellescape(a:template_prefix . '*' ) . '`'
		call s:Debug('Executing ' . l:find_cmd)
		let l:glob_results = glob(l:find_cmd)
		if v:shell_error != 0
			call s:Debug('Could not execute find command')
			unlet l:glob_results
		endif
	endif
	if !exists('l:glob_results')
		call s:Debug('Using fallback glob')
		let l:glob_results = glob(a:path . a:template_prefix . '*')
	endif
	let l:templates = split(l:glob_results, '\n')
	for template in l:templates
		" Make sure the template is readable
		if filereadable(template)
			let l:current_score =
						\ s:TemplateBaseNameTest(template, a:template_prefix, a:file_name)
			call s:Debug('template: ' . template . ' got scored: ' . l:current_score)

			" Pick that template only if it beats the currently picked template
			" (here we make the assumption that template name length ~= template
			" specifity / score)
			if l:current_score > l:picked_template_score
				let l:picked_template = template
				let l:picked_template_score = l:current_score
			endif
		endif
	endfor

	if !empty(l:picked_template)
		call s:Debug('Picked template: ' . l:picked_template)
	else
		call s:Debug('No template found')
	endif

	return l:picked_template
endfunction

" Searches for a [template] in a given [path].
"
" If [height] is [-1] the template is searched for in the given directory and
" all parents in its directory structure
"
" If [height] is [0] no searching is done in the given directory or any
" parents
"
" If [height] is [1] only the given directory is searched
"
" If [height] is greater than one, n parents and the given directory will be
" searched where n is equal to height - 1
"
" If no template is found an empty string is returned.
"
function! s:TSearch(path, template_prefix, file_name, height) abort
	if (a:height != 0)

		" pick a template from the current path
		let l:picked_template = s:TDirectorySearch(a:path, a:template_prefix, a:file_name)
		if !empty(l:picked_template)
			return l:picked_template
		else
			let l:pathUp = s:DirName(a:path)
			if l:pathUp !=# a:path
				let l:new_height = a:height >= 0 ? a:height - 1 : a:height
				return s:TSearch(l:pathUp, a:template_prefix, a:file_name, l:new_height)
			endif
		endif
	endif

	" Ooops, either we cannot go up in the path or [height] reached 0
	return ''
endfunction


" Tries to find valid templates using the global g:templates_name_prefix as a glob
" matcher for template files. The search is done as follows:
"   1. The [path] passed to the function, [upwards] times up.
"   2. The g:templates_directory directory, if it exists.
"   3. Built-in templates from s:default_template_dir.
" Returns an empty string if no template is found.
"
function! s:TFind(path, name, up) abort
	let l:tmpl = s:TSearch(a:path, g:templates_name_prefix, a:name, a:up)
	if !empty(l:tmpl)
		return l:tmpl
	endif

	for l:directory in g:templates_directory
		let l:directory = s:NormalizePath(expand(l:directory) . '/')
		if isdirectory(l:directory)
			let l:tmpl = s:TSearch(l:directory, g:templates_global_name_prefix, a:name, 1)
			if !empty(l:tmpl)
				return l:tmpl
			endif
		endif
	endfor

	if g:templates_no_builtin_templates
		return ''
	endif

	return s:TSearch(s:NormalizePath(expand(s:default_template_dir) . '/'), g:templates_global_name_prefix, a:name, 1)
endfunction

" Escapes a string for use in a regex expression where the regex uses / as the
" delimiter. Must be used with Magic Mode off /V
"
function! s:EscapeRegex(raw) abort
	return escape(a:raw, '/')
endfunction

" Makes a single [variable] expansion, using [value] as replacement.
"
function! s:TExpand(variable, value) abort
	silent! execute "%s/\\V%" . s:EscapeRegex(a:variable) . "%/" .  s:EscapeRegex(a:value) . "/g"
endfunction

" Performs variable expansion in a template once it was loaded {{{2
"
function! s:TExpandVars() abort
	" Date/time values
	let l:day        = strftime("%d")
	let l:year       = strftime("%Y")
	let l:month      = strftime("%m")
	let l:monshort   = strftime("%b")
	let l:monfull    = strftime("%B")
	let l:time       = strftime("%H:%M")
	let l:date       = exists("g:dateformat") ? strftime(g:dateformat) :
				     \ (l:year . "-" . l:month . "-" . l:day)
	let l:fdate      = l:date . " " . l:time
	let l:filen      = expand("%:t:r:r:r")
	let l:filex      = expand("%:e")
	let l:filec      = expand("%:t")
	let l:fdir       = expand("%:p:h:t")
	let l:hostn      = hostname()
	let l:user       = exists("g:username") ? g:username :
				     \ (exists("g:user") ? g:user : $USER)
	let l:email      = exists("g:email") ? g:email : (l:user . "@" . l:hostn)
	let l:guard      = toupper(substitute(l:filec, "[^a-zA-Z0-9]", "_", "g"))
	let l:class      = substitute(l:filen, "\\([a-zA-Z]\\+\\)", "\\u\\1\\e", "g")
	let l:macroclass = toupper(l:class)
	let l:camelclass = substitute(l:class, "_", "", "g")

	" Finally, perform expansions
	call s:TExpand("DAY",   l:day)
	call s:TExpand("YEAR",  l:year)
	call s:TExpand("DATE",  l:date)
	call s:TExpand("TIME",  l:time)
	call s:TExpand("USER",  l:user)
	call s:TExpand("FDATE", l:fdate)
	call s:TExpand("MONTH", l:month)
	call s:TExpand("MONTHSHORT", l:monshort)
	call s:TExpand("MONTHFULL",  l:monfull)
	call s:TExpand("FILE",  l:filen)
	call s:TExpand("FFILE", l:filec)
	call s:TExpand("FDIR",  l:fdir)
	call s:TExpand("EXT",   l:filex)
	call s:TExpand("MAIL",  l:email)
	call s:TExpand("HOST",  l:hostn)
	call s:TExpand("GUARD", l:guard)
	call s:TExpand("CLASS", l:class)
	call s:TExpand("MACROCLASS", l:macroclass)
	call s:TExpand("CAMELCLASS", l:camelclass)
	call s:TExpand("LICENSE", exists("g:license") ? g:license : "MIT")

	" Perform expansions for user-defined variables
	for [l:varname, l:funcname] in g:templates_user_variables
		let l:value = function(funcname)()
		call s:TExpand(l:varname, l:value)
	endfor
endfunction

" Puts the cursor either at the first line of the file or in the place of
" the template where the %HERE% string is found, removing %HERE% from the
" template.
"
function! s:TPutCursor() abort
	0  " Go to first line before searching
	if search("%HERE%", "W")
		let l:column = col(".")
		let l:lineno = line(".")
		s/%HERE%//
		call cursor(l:lineno, l:column)
	endif
endfunction

" Ensures that the given file name is safe to be opened and will not be shell
" expanded
function! s:NeuterFileName(filename) abort
	let l:neutered = fnameescape(a:filename)
	call s:Debug('Neutered ' . a:filename . ' to ' . l:neutered)
	return l:neutered
endfunction

" Load the given file as a template
function! s:TLoadTemplate(template, position) abort
	if !empty(a:template)
		let l:deleteLastLine = 0
		if line('$') == 1 && empty(getline(1))
			let l:deleteLastLine = 1
		endif

		" Read template file and expand variables in it.
		let l:safeFileName = s:NeuterFileName(a:template)
		if a:position == 0
			execute 'keepalt 0r ' . l:safeFileName
		else
			execute 'keepalt r ' . l:safeFileName
		endif
		call s:TExpandVars()

		if l:deleteLastLine == 1
			" Loading a template into an empty buffer leaves an extra blank line at the bottom, delete it
			execute line('$') . 'd _'
		endif

		call s:TPutCursor()
		setlocal nomodified
	endif
endfunction

" Loads a template for the current buffer, substitutes variables and puts
" cursor at %HERE%. Used to implement the BufNewFile autocommand.
"
function! template#load() abort
	if !line2byte(line('$') + 1) == -1
		return
	endif
	let l:file_name = expand('%:p')
	let l:file_dir = s:DirName(l:file_name)
	let l:depth = g:templates_search_height
	let l:tFile = s:TFind(l:file_dir, l:file_name, l:depth)
	call s:TLoadTemplate(l:tFile, 0)
endfunction

" Like template#load(), but intended to be called with an argument
" that either is a filename (so the file is loaded as a template) or
" a template suffix (and the template is searched as usual). Of course this
" makes variable expansion and cursor positioning.
"
function! template#load_command(template, position) abort
	if filereadable(a:template)
		let l:tFile = a:template
	else
		let l:height = g:templates_search_height
		let l:tName = g:templates_global_name_prefix . a:template
		let l:file_name = expand('%:p')
		let l:file_dir = s:DirName(l:file_name)
		let l:tFile = s:TFind(l:file_dir, a:template, l:height)
	endif
	call s:TLoadTemplate(l:tFile, a:position)
endfunction

function! template#suffix_list(A, P, L) abort
  let l:templates = split(globpath(s:default_template_dir, g:templates_global_name_prefix . a:A . '*'), '\n')
  let l:res = []
  for t in templates
    let l:suffix = substitute(t, ".*\\.", "", "")
    call add(l:res, l:suffix)
  endfor
  return l:res
endfunction


let &cpoptions = s:saved_cpoptions
unlet s:saved_cpoptions