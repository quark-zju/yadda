###*
# @provides yadda-home
# @requires coffeescript
# @requires lodash
# @requires moment
# @requires react
# @requires react-dom
###

redraw = -> return

state =
  # state that will be synchronized to remote periodically
  remote: {updatedAt: 0}

  # define a property that syncs with localStorage, optionally sync with remote
  defineSyncedProperty: (name, fallback=null, remote=false) ->
    if _.isString(fallback)
      loads = dumps = (x) -> x
    else
      loads = JSON.parse
      dumps = JSON.stringify
    Object.defineProperty state, name,
      enumerable: false, configurable: false
      get: ->
        v = null
        # try remote first
        if remote && state.remote[name]
          v = state.remote[name]
        # fallback to localStorage
        if v == null || v == undefined
          try
            v = loads(localStorage[name])
        # replace "null" or "undefined" (but not "false") to fallback
        if v == null || v == undefined
          v = fallback
        v
      set: (v) ->
        if _.isEqual(v, fallback)
          localStorage.removeItem name
          if remote && state.remote[name]
            delete state.remote[name]
        else
          localStorage[name] = dumps(v)
          if remote
            state.remote[name] = v
        if remote
          state.remote.updatedAt = moment.now()

        redraw()

# utility: copy
copy = (text) ->
  if not text
    return
  t = document.createElement('textarea')
  t.style.position = 'fixed'
  t.style.bottom = 0
  t.style.right = 0
  t.style.width = '50px'
  t.style.height = '20px'
  t.style.border = 'none'
  t.style.outline = 'none'
  t.style.boxShadow = 'none'
  t.style.background = 'transparent'
  t.style.opacity = '0.1'
  t.value = text
  document.body.appendChild t
  t.select()
  try
    document.execCommand('copy')
  finally
    document.body.removeChild t

_init = ->
  # whether to sync remotely, default true. The option itself won't be synced.
  state.defineSyncedProperty 'sync', true, false
  state.defineSyncedProperty 'code', yaddaDefaultCode, state.sync

  _request = (path, data, callback) ->
    # JX.Request handles CSRF token (see javelin-behavior-refresh-csrf)
    req = new (JX.Request)(path, callback)
    req.setResponseType('JSON')
    req.setExpectCSRFGuard(false)
    if data
      req.setData(data)
    req.send()

  _editorWin = null
  _cached = {}
  _compile = (code) -> # compile code, return [scope, error]
    if _cached.code != code
      _cached.code = code
      try
        bare = CoffeeScript.compile(code, bare: true)
        scope = {}
        code = "(function() { #{bare} }).call(scope);"
        eval code
        _cached.err = null
      catch err
        if __DEV__
          window.err = err
        _cached.err = err
      _cached.scope = scope
    return [(_cached.scope || {}), _cached.err]

  {div, span} = React.DOM
  class Root extends React.Component
    handleCodeReset: ->
      if confirm('Do you want to remove customization and use the default Yadda UI code? This cannot be undone.')
        state.code = yaddaDefaultCode
        _editorWin?.setCode yaddaDefaultCode # NOTE: not working across reloads

    render: ->
      code = state.code
      content = null
      errors = []
      [scope, err] = _compile(code)
      if err
        errors.push err

      if scope.render
        try
          content = scope.render(state)
        catch err
          errors.push err
      else
        errors.push new Error('render(state) function needs to be defined')

      div null,
        errors.map (e, i) ->
          div key: i, className: 'phui-info-view phui-info-severity-warning', title: e.stack,
            e.toString(),
        content
        if code && code != yaddaDefaultCode
          span className: 'hint-code-different', onDoubleClick: @handleCodeReset, title: 'The code driven this page has been changed so it is different from the default. If that is not intentional, double click to restore to the default code.'

  element = React.createElement(Root)
  node = ReactDOM.render element, document.querySelector('.yadda-root')
  redraw = -> node.forceUpdate()

  _lastRemoteSync = state.remote.updatedAt
  _syncTick = ->
    if !state.user
      return
    remote = state.remote
    if remote.updatedAt > _lastRemoteSync
      _lastRemoteSync = remote.updatedAt
      _request '/api/yadda.setstate', data: JSON.stringify(remote)
  setInterval _syncTick, 2200

  refresh = ->
    _processResult = (result) ->
      state.revisions = result.revisions
      state.user = result.user
      state.profileMap = _.keyBy(result.profiles, (p) -> p.userName)
      remote = null
      try
        remote = JSON.parse(result.state)
      if remote && remote.updatedAt > state.remote.updatedAt
        _lastRemoteSync = remote.updatedAt
        state.remote = remote
      redraw()

    stateElement = document.querySelector('.yadda-non-logged-in-state')
    if stateElement
      _processResult JSON.parse(stateElement.textContent)
    else
      _request '/api/yadda.query', null, (r) ->
        if r.result
          state.updatedAt = moment()
          state.error = null
          _processResult r.result
        else
          state.error = (r.error_info || 'Server does not return expected data')
          redraw()

  _tick = 0
  _refreshTick = ->
    if document.hidden
      _tick = 0 # refresh when the page gets focused back
    else
      if _tick == 0
        redraw() # take localStorage changes that are possibly made by other tabs
        refresh()
      _tick = (_tick + 1) % 150 # 2.5 minutes
  _refreshTick()
  setInterval _refreshTick, 1000

  # Receive code change messages broadcasted from the code editor window.
  # This works across reloads (document and the state here get lost).
  _handleWindowMessage = (e) ->
    if e.data.type == 'code-change'
      state.code = e.data.value
  window.addEventListener 'message', _handleWindowMessage, false

  # Function to create the editor window
  popupEditor = ->
    if _editorWin && !_editorWin.closed
      new JX.Notification().setContent('The editor window was open.\n(hint: set localStorage.editorType to "plain" to use a plain editor)').setDuration(16000).show()
      return
    _editorWin = window.open('', '', 'width=600,height=800')
    _editorWin._parent = window
    doc = _editorWin.document
    doc.head.innerHTML = '''
    <title>Yadda Live Editor</title>
    <style>html, body, div { padding: 0; margin: 0; overflow: hidden; }
      .editor { position: absolute; top: 0; right: 0; bottom: 0; left: 0; width: 100%; height: 100%; }</style>
    '''
    # Execute javascript in that window by "_editorWin.eval" so closing this
    # window won't cause event listeners etc. to lose for that window.
    runScript = (coffee) -> _editorWin.eval CoffeeScript.compile(coffee)
    runScript """
      markAsDisconnect = -> document.title = '(Disconnected)'
      window.postCode = (code) -> _parent.postMessage({'type': 'code-change', 'value': code}, #{JSON.stringify(window.location.origin)})
      checkAlive = ->
        if !_parent || _parent.closed
          markAsDisconnect()
      setInterval checkAlive, 1000
      """

    useTextarea = ->
      doc.body.innerHTML = '<textarea class="editor" spellcheck="false" wrap="soft" style="border: none; resize: none; white-space: pre;"></textarea>'
      runScript """
        editor = document.querySelector('.editor')
        editor.addEventListener 'input', (e) -> postCode e.target.value
        window.setCode = (code) -> document.querySelector('.editor').value = code
        """
      _editorWin.setCode state.code || yaddaDefaultCode

    useAce = ->
      doc.body.innerHTML = '<div class="editor"></div>'
      runScript """
        editor = ace.edit document.querySelector('.editor')
        editor.getSession().setOptions tabSize: 2, useSoftTabs: true
        editor.getSession().setMode 'ace/mode/coffee'
        editor.setSelectionStyle 'text'
        editor.setShowPrintMargin false
        editor.getSession().on 'change', (e) -> window.postCode editor.getValue()
        window.setCode = (code) ->
          editor.setValue.bind(editor)(code)
          editor.clearSelection()
        window.editor = editor
        """
      _editorWin.setCode state.code || yaddaDefaultCode

    # Load ACE editor (best-effort)
    if (localStorage['editorType'] || 'ace') == 'ace'
      script = doc.createElement('script')
      script.onload = useAce
      script.onerror = useTextarea
      script.src = 'https://cdnjs.cloudflare.com/ajax/libs/ace/1.2.8/ace.js'
      doc.head.appendChild(script)
    else
      useTextarea()

  # The only way to access the editor is the "~" key.
  k = new JX.KeyboardShortcut(['~'], 'Pop-up live code editor.')
  k.setHandler popupEditor
  k.register()

  if __DEV__
    window.state = state
    window._cached = _cached

document.addEventListener 'DOMContentLoaded', _init
