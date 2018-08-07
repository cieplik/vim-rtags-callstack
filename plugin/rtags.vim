" TODO Keep locations in loclist, not buffer
" TODO Highligh up the stack, if unique

if !exists("g:numSigns")
    for idx in range(0, 9)
        execute "sign define stackdepth" . string(idx) . " text=" . string(idx) . ">"
    endfor
    let g:numSigns = 1
endif

function! rtags#GetParentLocation(results)
    for line in a:results
        let matched = matchend(line, "^Parent: ")
        if matched == -1
            continue
        endif
        let [jump_file, lnum, col] = rtags#parseSourceLocation(line[matched:-1])
        if !empty(jump_file)
            return jump_file . ':' . lnum . ':' . col
        endif
    endfor
endfunction

function! rtags#Highlight(...)
    execute "sign unplace * buffer=" . string(bufnr("%"))

    function! PlaceStackDepth(line, depth)
        execute "sign place 43 line=" . string(a:line) . " name=stackdepth"
            \ . string(min([9, a:depth])) . " buffer=" . string(bufnr("%"))
    endfunction

    function! PlaceSameDepth(depth, locations, range)
        for idx in a:range
            if a:locations[idx].depth == a:depth
                call PlaceStackDepth(idx + 1, a:depth)
            elseif a:locations[idx].depth < a:depth
                break
            endif
        endfor
    endfunction

    let locations = rtags#GetLocations()
    let depth = locations[line(".") - 1].depth
    call PlaceSameDepth(depth, locations, range(line('.') - 1, len(locations) - 1))
    call PlaceSameDepth(depth, locations, range(line('.') - 1, 0, -1))

    echo locations[line(".") - 1].caller

    let lines = [line(".")]

    for idx in range(line(".") - 1, 0, -1)
        if locations[idx].depth == depth - 1
            let depth = depth - 1
            call PlaceStackDepth(idx + 1, depth)
            call add(lines, idx + 1)
        endif
    endfor

    if exists("b:prevMatch")
        call matchdelete(b:prevMatch)
    endif
    let b:prevMatch = matchaddpos("Error", lines)
endfunction

function! rtags#UpdateLocations(results, locationPrototype)
    let newLocations = []
    for result in a:results
        let thisLocation = deepcopy(a:locationPrototype)
        let thisLocation.caller = result.caller
        call add(newLocations, thisLocation)
    endfor
    let locations = rtags#GetLocations()
    call extend(locations, newLocations, min([len(locations), line(".")]))
endfunction

function! rtags#ShortenCallsite(results)
    for entry in a:results
        let entry.caller = substitute(entry.text, '.* function: ', '', '')
        let entry.text = substitute(entry.text, ' function: .*', '', '')
    endfor
endfunction

function! rtags#getCurrentLocation()
    let [lnum, col] = getpos('.')[1:2]
    return printf('%s:%s:%s', expand('%:p'), lnum, col)
endfunction

function! rtags#AddParents(result, locations)
    if len(a:result) > 0
        call rtags#ExecuteThen({
          \ '-r': rtags#GetParentLocation(a:result),
          \ '--containing-function': ''},
          \ [[function('rtags#AddReferences'), a:locations], [function('rtags#Highlight'), 0]])
    endif
endfunction

function! rtags#GetLoclist()
    return getloclist(0)
endfunction

function! rtags#GetLocations()
    if exists('b:locations') == 0
        let b:locations = []
    endif
    return b:locations
endfunction

function! rtags#SetLocations(locations)
    let b:locations = a:locations
endfunction

function! rtags#AddReferences(results, locations)
    let results = rtags#ParseResults(a:results)
    call rtags#ShortenCallsite(results)
    call rtags#UpdateLocations(results, a:locations)
    let oldpos = winsaveview()
    call setloclist(0, extend(rtags#GetLoclist(), results, line(".")))
    call winrestview(oldpos)
endfunction

function! s:ExpandReferences()
    let entry = rtags#GetLoclist()[line(".") - 1]

    let location = fnamemodify(bufname(entry.bufnr), ":p") . ':' . entry.lnum . ':' . entry.col

    let args = { '-U': location, '--symbol-info-include-parents' : '' }

    call rtags#ExecuteThen(args, [[function('rtags#AddParents'), {"depth": rtags#GetLocations()[line(".") - 1]["depth"] + 1}]])
endfunction

function! rtags#SetupMappings(results, currentLocation)
    if g:rtagsUseLocationList == 1
        let res = rtags#ParseResults(a:results)
        call rtags#SetLocations([])
        call rtags#ShortenCallsite(res)
        call rtags#UpdateLocations(res, {"callee": a:currentLocation, "depth": 0})
        nnoremap <buffer> o :call <SID>ExpandReferences()<CR>
        au CursorMoved <buffer> call rtags#Highlight()
    endif
endfunction

function! rtags#DisplayCallTree(results)
    let locations = rtags#ParseResults(a:results)
    call rtags#ShortenCallsite(locations)
    call rtags#DisplayLocations(locations)
    return a:results
endfunction

function! rtags#FindRefsCallTree()
    let args = { '-r': rtags#getCurrentLocation(), '--containing-function': ''}

    call rtags#SetLocations([])
    call rtags#ExecuteThen(args, [function('rtags#DisplayCallTree'), [function('rtags#SetupMappings'), rtags#getCurrentLocation()]])
endfunction
