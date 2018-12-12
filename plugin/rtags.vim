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

    function! MatchDelete()
        if exists("b:prevMatch")
            call matchdelete(b:prevMatch)
            unlet b:prevMatch
        endif
    endfunction

    if !rtags#HasCallstack() || len(rtags#GetLocations()) == 0
        call MatchDelete()
        return
    endif

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

    echo substitute(locations[line(".") - 1].caller, '\v\(.*$', '', '')

    let lines = [line(".")]

    for idx in range(line(".") - 1, 0, -1)
        if locations[idx].depth == depth - 1
            let depth = depth - 1
            call PlaceStackDepth(idx + 1, depth)
            call add(lines, idx + 1)
        endif
    endfor

    let currMatch = matchadd(
      \ 'Error',
      \ '\v(' . join(map(lines, '"%" . v:val . "l"'), '|') . ')\|[0-9]+ col [0-9]+ r\| \zs.*$')
    call MatchDelete()
    let b:prevMatch = currMatch
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
    return getloclist(0, {'items': 1})['items']
endfunction

function! rtags#SetLoclist(items)
    call setloclist(0, [], 'r', {'items': a:items})
endfunction

function! rtags#GetContext()
    return getloclist(0, {'context': 1}).context
endfunction

function! rtags#SetContext(context)
    call setloclist(0, [], 'r', {'context': a:context})
endfunction

function! rtags#SetInContext(key, value)
    let context = rtags#GetContext()
    let context[a:key] = a:value
endfunction

function! rtags#SetLocations(locations)
    call rtags#SetInContext('locations', a:locations)
endfunction

function! rtags#GetLocations()
    return rtags#GetContext().locations
endfunction

function! rtags#WinSaveView()
    if rtags#HasCallstack()
        call rtags#SetInContext('winview', winsaveview())
    endif
endfunction

function! rtags#WinRestView()
    call winrestview(rtags#GetContext().winview)
endfunction

function! rtags#AddReferences(results, locations)
    let results = rtags#ParseResults(a:results)
    call rtags#ShortenCallsite(results)
    call rtags#UpdateLocations(results, a:locations)
    let oldpos = winsaveview()
    call rtags#SetLoclist(extend(rtags#GetLoclist(), results, line(".")))
    call rtags#UpdateLocationWindowHeight()
    call winrestview(oldpos)
endfunction

function! s:ExpandReferences()
    if !rtags#HasCallstack()
        return
    endif

    let entry = rtags#GetLoclist()[line(".") - 1]

    let location = fnamemodify(bufname(entry.bufnr), ":p") . ':' . entry.lnum . ':' . entry.col

    let args = { '-U': location, '--symbol-info-include-parents' : '' }

    call rtags#ExecuteThen(args, [[function('rtags#AddParents'), {"depth": rtags#GetLocations()[line(".") - 1]["depth"] + 1}]])
endfunction

function! rtags#SetupMappings(results, currentLocation)
    if g:rtagsUseLocationList == 1
        let res = rtags#ParseResults(a:results)
        call rtags#SetLocations([])
        if len(res) == 0
            echo "No callsites found"
            return
        endif
        call rtags#ShortenCallsite(res)
        call rtags#UpdateLocations(res, {"callee": a:currentLocation, "depth": 0})
    endif
endfunction

function! rtags#UpdateLocationWindowHeight()
    let height = min([
      \ g:rtagsMaxSearchResultWindowHeight,
      \ len(rtags#GetLoclist())])

    if height != 0
        if exists('b:rtagsLoclistInitialized')
            let height = max([height, winheight(0)])
        endif

        execute 'lopen ' . height | set nowrap
    endif
endfunction

function! rtags#DisplayCallTree(results)
    let locations = rtags#ParseResults(a:results)
    call rtags#ShortenCallsite(locations)

    if len(locations) > 0
        call rtags#SetLoclist(locations)
        call rtags#UpdateLocationWindowHeight()
    endif

    return a:results
endfunction

function! rtags#HasCallstack()
    let context = rtags#GetContext()
    return type(context) == type({}) && has_key(context, 'rtagsCallstack')
endfunction

function! rtags#FindRefsCallTree()
    let context = rtags#GetContext()
    if !rtags#HasCallstack()
    " type(context) != type({}) || !has_key(context, 'rtagsCallstack')
        call rtags#SetContext({'rtagsCallstack': 1, 'locations': []})
    endif

    let args = { '-r': rtags#getCurrentLocation(), '--containing-function': ''}

    call rtags#SetLocations([])
    call rtags#ExecuteThen(args, [function('rtags#DisplayCallTree'), [function('rtags#SetupMappings'), rtags#getCurrentLocation()]])
endfunction

function! rtags#SetupLocationList()
    if !rtags#HasCallstack() || exists('b:rtagsLoclistInitialized')
        return
    endif
    let b:rtagsLoclistInitialized = 1

    if len(rtags#GetLocations()) != 0
        call rtags#WinRestView()
        call rtags#Highlight()
    endif

    au CursorMoved <buffer> call rtags#Highlight()
    au WinLeave <buffer> call rtags#WinSaveView()
    nnoremap <buffer> o :call <SID>ExpandReferences()<CR>
endfunction

au FileType qf call rtags#SetupLocationList()
