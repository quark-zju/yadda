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
        if remote
          v = state.remote[name]
        else
          try
            v = loads(localStorage[name])
        # replace "null" or "undefined" (but not "false") to fallback
        if v == null || v == undefined
          # code may modify fallback by mistake
          v = _.clone(fallback)
        v
      set: (v) ->
        d = dumps(v)
        if _.isEqual(v, fallback) && d.length > 32 # optimization: do not store long default values
          if remote
            delete state.remote[name]
          else
            localStorage.removeItem name
        else
          if remote
            state.remote[name] = v
          else
            localStorage[name] = d
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

# utility: key for easy keyboard shortcut registering
_registeredKeys = {}
shortcutKey = (keys, desc, handler) ->
  name = JSON.stringify(keys)
  if _registeredKeys[name]
    k = _registeredKeys[name]
  else
    k = (new JX.KeyboardShortcut(keys, desc)).setHandler(handler)
    _registeredKeys[name] = k
    k.register()
  k.setDescription(desc)
  k.setHandler(handler)

triggerShortcutKey = (key) ->
  for name, entry of _registeredKeys
    if _.includes(JSON.parse(name), key)
      entry.getHandler()()

# utility: JX.Notification
notify = (content, duration = 3000) ->
  notif = new JX.Notification().setContent(content).setDuration(duration)
  if notif.setWebReady
    # new API added by https://secure.phabricator.com/D18457
    notif.setWebReady true
  notif.show()

CODE_SOURCE_REMOTE = 'remote'
CODE_SOURCE_LOCAL = 'local'
CODE_SOURCE_BUILTIN = 'builtin'

_init = ->
  # whether to sync code remotely (use state.remote.code), or just locally (use
  # state.code), or use default code (use yaddaDefaultCode).
  state.defineSyncedProperty 'configCodeSource', CODE_SOURCE_BUILTIN, true
  state.defineSyncedProperty 'code', yaddaDefaultCode
  _getCode = ->
    src = state.configCodeSource
    code = ''
    if src == CODE_SOURCE_REMOTE
      code = state.remote.code
    else if src == CODE_SOURCE_LOCAL
      code = state.code
    if !_.isString(code) || code.length == 0
      code = yaddaDefaultCode
    code

  _request = (path, data, callback, onError) ->
    # JX.Request handles CSRF token (see javelin-behavior-refresh-csrf)
    req = new (JX.Request)(path, callback)
    if onError
      req.listen 'error', onError
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

  {a, button, div, pre, span} = React.DOM
  class Root extends React.Component
    handleCodeReset: ->
      src = state.configCodeSource
      state.configCodeSource = CODE_SOURCE_BUILTIN
      furtherRestore = null
      if src == CODE_SOURCE_LOCAL
        furtherRestore = ->
          if confirm('Restored to built-in UI. Do you also want to discard UI customization stored in localStorage?')
            state.code = ''
            state.configCodeSource = CODE_SOURCE_LOCAL
      else if src == CODE_SOURCE_REMOTE
        furtherRestore = ->
          if confirm('Restored to built-in UI. Do you also want to discard UI customization stored in Phabricator server?')
            state.remote.code = ''
            state.remote.updatedAt = moment.now()
            state.configCodeSource = CODE_SOURCE_REMOTE
      if furtherRestore
        setTimeout furtherRestore, 500

    render: ->
      code = _getCode()
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
          div key: i, className: 'phui-info-view phui-info-severity-warning',
            e.toString()
            if e.stack
              pre style: {padding: 8, marginTop: 8, backgroundColor: '#EBECEE', overflow: 'auto'},
                e.stack
        if errors.length > 0
          div className: 'phui-info-view phui-info-severity-notice grouped',
            'You can switch to the default UI, and optionally discard the code change to resolve errors.'
            div className: 'phui-info-view-actions',
              button className: 'phui-button-default', onClick: @handleCodeReset, 'Restore UI'
        content
        # bottom-left triangle
        if code && code != yaddaDefaultCode
          span className: 'hint-code-different', onDoubleClick: @handleCodeReset, title: 'The code rendering this page has been changed so it is different from the built-in version. If anything breaks, double click to restore to the built-in version.'

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
      showError = (msg) ->
        if _.isString(msg) && msg.length > 0
          msg = " (#{msg})"
        else
          msg = ''
        notify "Failed to sync state with Phabricator server#{msg}. Check network connection or refresh this page.", 8000
      _request '/api/yadda.setstate', data: JSON.stringify(remote), ((r) -> r.error_info && showError(r.error_info)), showError
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
      src = state.configCodeSource
      if src == CODE_SOURCE_BUILTIN
        # CODE_SOURCE_BUILTIN is immutable. Change to "remote" automatically.
        state.configCodeSource = src = CODE_SOURCE_REMOTE
      if src == CODE_SOURCE_LOCAL
        state.code = e.data.value
      else if src == CODE_SOURCE_REMOTE
        state.remote.code = e.data.value
        state.remote.updatedAt = moment.now()
        redraw()
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
      _editorWin.setCode _getCode()

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
      _editorWin.setCode _getCode()

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
  shortcutKey ['~'], 'Open live interface editor.', popupEditor

  if __DEV__
    window.state = state

document.addEventListener 'DOMContentLoaded', _init
