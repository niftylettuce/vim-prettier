let s:root_dir = fnamemodify(resolve(expand('<sfile>:p')), ':h')
let s:prettier_job_running = 0
let s:prettier_quickfix_open = 0

function! prettier#Prettier(...) abort
  let l:execCmd = s:Get_Prettier_Exec()
  let l:async = a:0 > 0 ? a:1 : 0
  let l:startSelection = a:0 > 1 ? a:2 : 1
  let l:endSelection = a:0 > 2 ? a:3 : line('$')
  let l:config = getbufvar(bufnr('%'), 'prettier_ft_default_args', {})

  if l:execCmd != -1
    let l:cmd = l:execCmd . s:Get_Prettier_Exec_Args(l:config)

    " close quickfix if it is opened 
    if s:prettier_quickfix_open
      call setqflist([])
      cclose
      let s:prettier_quickfix_open = 0
    endif

    if l:async && v:version >= 800 && exists('*job_start')
      call s:Prettier_Exec_Async(l:cmd, l:startSelection, l:endSelection)
    else
      call s:Prettier_Exec_Sync(l:cmd, l:startSelection, l:endSelection)
    endif
  else
    call s:Suggest_Install_Prettier()
  endif
endfunction

function! prettier#Autoformat(...) abort
  let l:curPos = getpos('.')
  let l:maxLineLookup = 50
  let l:maxTimeLookupMs = 500
  let l:pattern = '@format'

  " we need to move selection to the top before looking up to avoid
  " scanning a very long file
  call cursor(1, 1)

  " Search starting at the start of the document
  if search(l:pattern, 'n', l:maxLineLookup, l:maxTimeLookupMs) > 0
    " autoformat async
    call prettier#Prettier(1)
  endif

  " Restore the selection and if greater then before it defaults to end
  call cursor(curPos[1], curPos[2])
endfunction

function! s:Prettier_Exec_Sync(cmd, startSelection, endSelection) abort
  let l:bufferLinesList = getbufline(bufnr('%'), a:startSelection, a:endSelection)

  " vim 7 does not have support for passing a list to system()
  let l:bufferLines = v:version <= 800 ? join(l:bufferLinesList, "\n") : l:bufferLinesList

  let l:out = split(system(a:cmd, l:bufferLines), '\n')

  " check system exit code
  if v:shell_error
    call s:Prettier_Parse_Error(l:out)
    return
  endif

  if (s:Has_Content_Changed(l:out, a:startSelection, a:endSelection) == 0)
    return
  endif

  call s:Apply_Prettier_Format(l:out, a:startSelection, a:endSelection)
endfunction

function! s:Prettier_Exec_Async(cmd, startSelection, endSelection) abort
  let l:async_cmd = a:cmd

  if has('win32') || has('win64')
    let l:async_cmd = 'cmd.exe /c ' . a:cmd
  endif

  if s:prettier_job_running != 1
      let s:prettier_job_running = 1
      call job_start(l:async_cmd, {
        \ 'in_io': 'buffer',
        \ 'in_top': a:startSelection,
        \ 'in_bot': a:endSelection,
        \ 'in_name': bufname('%'),
        \ 'err_cb': {channel, msg -> s:Prettier_Job_Error(msg)},
        \ 'close_cb': {channel -> s:Prettier_Job_Close(channel, a:startSelection, a:endSelection)}})
  endif
endfunction

function! s:Prettier_Job_Close(channel, startSelection, endSelection) abort
  let l:out = []

  while ch_status(a:channel, {'part': 'out'}) == 'buffered'
    call add(l:out, ch_read(a:channel))
  endwhile

  " nothing to update
  if (s:Has_Content_Changed(l:out, a:startSelection, a:endSelection) == 0)
    let s:prettier_job_running = 0
    return
  endif

  if len(l:out)
    call s:Apply_Prettier_Format(l:out, a:startSelection, a:endSelection)
    write
    let s:prettier_job_running = 0
  endif
endfunction

function! s:Prettier_Job_Error(msg) abort
    call s:Prettier_Parse_Error(split(a:msg, '\n'))
    let s:prettier_job_running = 0
endfunction

function! s:Handle_Parsing_Errors(out) abort
  let l:errors = []

  for line in a:out
    " matches:
    " stdin: SyntaxError: Unexpected token (2:8)
    let l:match = matchlist(line, '^stdin: \(.*\) (\(\d\{1,}\):\(\d\{1,}\)*)')
    if !empty(l:match)
      call add(l:errors, { 'bufnr': bufnr('%'),
                         \ 'text': match[1],
                         \ 'lnum': match[2],
                         \ 'col': match[3] })
    endif
  endfor

  if len(l:errors)
    call setqflist(l:errors)
    botright copen
    let s:prettier_quickfix_open = 1
  endif
endfunction

function! s:Has_Content_Changed(content, startLine, endLine) abort
  return getbufline(bufnr('%'), 1, line('$')) == s:Get_New_Buffer(a:content, a:startLine, a:endLine) ? 0 : 1
endfunction

function! s:Get_New_Buffer(lines, start, end) abort
  return getbufline(bufnr('%'), 1, a:start - 1) + a:lines + getbufline(bufnr('%'), a:end + 1, '$')
endfunction

function! s:Apply_Prettier_Format(lines, startSelection, endSelection) abort
  " store cursor position
  let l:curPos = getpos('.')
  let l:newBuffer = s:Get_New_Buffer(a:lines, a:startSelection, a:endSelection)

  " delete all lines on the current buffer
  silent! execute 1 . ',' . line('$') . 'delete _'

  " replace all lines from the current buffer with output from prettier
  call setline(1, l:newBuffer)

  " restore cursor position
  call cursor(l:curPos[1], l:curPos[2])
endfunction

" By default we will default to our internal
" configuration settings for prettier
function! s:Get_Prettier_Exec_Args(config) abort
  " Allow params to be passed as json format
  " convert bellow usage of globals to a get function o the params defaulting to global
  let l:cmd = ' --print-width ' .
          \ get(a:config, 'printWidth', g:prettier#config#print_width) .
          \ ' --tab-width ' .
          \ get(a:config, 'tabWidth', g:prettier#config#tab_width) .
          \ ' --use-tabs ' .
          \ get(a:config, 'useTabs', g:prettier#config#use_tabs) .
          \ ' --semi ' .
          \ get(a:config, 'semi', g:prettier#config#semi) .
          \ ' --single-quote ' .
          \ get(a:config, 'singleQuote', g:prettier#config#single_quote) .
          \ ' --bracket-spacing ' .
          \ get(a:config, 'bracketSpacing', g:prettier#config#bracket_spacing) .
          \ ' --jsx-bracket-same-line ' .
          \ get(a:config, 'jsxBracketSameLine', g:prettier#config#jsx_bracket_same_line) .
          \ ' --trailing-comma ' .
          \ get(a:config, 'trailingComma', g:prettier#config#trailing_comma) .
          \ ' --parser ' .
          \ get(a:config, 'parser', g:prettier#config#parser) .
          \ ' --stdin '
  return cmd
endfunction

" By default we will search for the following
" => locally installed prettier inside node_modules on any parent folder
" => globally installed prettier
" => vim-prettier prettier installation
" => if all fails suggest install
function! s:Get_Prettier_Exec() abort
  let l:local_exec = s:Get_Prettier_Local_Exec()
  if executable(l:local_exec)
    return l:local_exec
  endif

  let l:global_exec = s:Get_Prettier_Global_Exec()
  if executable(l:global_exec)
    return l:global_exec
  endif

  let l:plugin_exec = s:Get_Prettier_Plugin_Exec()
  if executable(l:plugin_exec)
    return l:plugin_exec
  endif

  return -1
endfunction

function! s:Get_Prettier_Local_Exec() abort
  return s:Get_Exec(getcwd())
endfunction

function! s:Get_Prettier_Global_Exec() abort
  return s:Get_Exec()
endfunction

function! s:Get_Prettier_Plugin_Exec() abort
  return s:Get_Exec(s:root_dir)
endfunction

function! s:Get_Exec(...) abort
  let l:rootDir = a:0 > 0 ? a:1 : 0
  let l:exec = -1

  if isdirectory(l:rootDir)
    let l:dir = s:Tranverse_Dir_Search(l:rootDir)
    if dir != -1
      let l:exec = s:Get_Path_To_Exec(l:dir)
    endif
  else
    let l:exec = s:Get_Path_To_Exec()
  endif

  return exec
endfunction

function! s:Get_Path_To_Exec(...) abort
  let l:rootDir = a:0 > 0 ? a:1 : -1
  let l:dir = l:rootDir != -1 ? l:rootDir . '/.bin/' : ''
  return dir . 'prettier'
endfunction

function! s:Tranverse_Dir_Search(rootDir) abort
  let l:root = a:rootDir
  let l:dir = 'node_modules'

  while 1
    let l:search_dir = root . '/' . dir
    if isdirectory(l:search_dir)
      return l:search_dir
    endif

    let l:parent = fnamemodify(root, ':h')
    if l:parent == l:root
      return -1
    endif

    let l:root = l:parent
  endwhile
endfunction

function! s:Prettier_Parse_Error(errors) abort
  echohl WarningMsg | echom 'Prettier: failed to parse buffer.' | echohl NONE
  if g:prettier#quickfix_enabled
    call s:Handle_Parsing_Errors(a:errors)
  endif
endfunction

" If we can't find any prettier installing we then suggest where to get it from
function! s:Suggest_Install_Prettier() abort
  echohl WarningMsg | echom 'Prettier: no prettier executable installation found.' | echohl NONE
endfunction
