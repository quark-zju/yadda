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
  # - state.remote: in-memory volatile state; source of truth
  # - localStorage._pendingRemote: pending sync state; persistent across refreshes
  # - server side "state": could be older, or newer than the above
  remote:
    updatedAt: 0

  # define a property that syncs with localStorage, optionally sync with remote
  #
  # If remote is true, the state.remote[name] should be managed by state[name],
  # do not access state.remote[name] but only state[name] in that case.
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
        if __DEV__
          console.log "set state.#{name} remote=#{remote}"
        d = dumps(v)
        if _.isEqual(v, fallback) && d.length > 32 # optimization: do not store long default values
          if __DEV__
            console.log '  equal to fallback, remove item'
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
          state.remote.scheduleSync()

        redraw()

# Set default value for key, so it will be omitted by toJSON, save network traffic
_remoteDefaults = {}
Object.defineProperty state.remote, 'setDefault',
  writable: false, enumerable: false, configurable: false
  value: (name, fallback) ->
    _remoteDefaults[name] = fallback

Object.defineProperty state.remote, 'toJSON',
  writable: false, enumerable: false, configurable: false
  value: ->
    JSON.stringify(_.omitBy(state.remote, (v, k) -> _.isEqual(v, _remoteDefaults[k])))

Object.defineProperty state.remote, 'scheduleSync',
  writable: false, enumerable: false, configurable: false
  value: ->
    state.remote.updatedAt = moment.now()
    localStorage._pendingRemote = state.remote.toJSON() # write journal - backup state

# populate state.remote from localStorage as initial state
_applyNewRemote = (newRemote) ->
  for k, v of newRemote
    state.remote[k] = v
try
  _applyNewRemote(JSON.parse(localStorage._pendingRemote))

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
  if _.isString(keys)
    keys = [keys]
  name = JSON.stringify(keys)
  if _registeredKeys[name]
    k = _registeredKeys[name]
  else
    k = (new JX.KeyboardShortcut(keys, desc)).setHandler(handler)
    _registeredKeys[name] = k
    for keyName in keys
      _registeredKeys[keyName] = k
    k.register()
  k.setDescription(desc)
  k.setHandler(handler)

triggerShortcutKey = (key) ->
  _registeredKeys[key]?.getHandler()()

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

_getCodePropName = (basename) ->
  if basename == 'entry'
    'code' # for backwards compatibility
  else
    "code#{_.capitalize(basename)}"

_init = ->
  # initial state from the server
  initial = {}
  try
    initial = JSON.parse(document.querySelector('.yadda-initial').textContent)

  # default code may be mangled
  if initial.appendScript
    YADDA_DEFAULT_SCRIPT_NAMES.push 'extra'
    YADDA_DEFAULT_SCRIPTS['extra'] = """
      # Extra code from Phabricator 'yadda.append-script' server-side config
      #{initial.appendScript}
      """

  # whether to sync code remotely (use state.remote.code), or just locally (use
  # state.code), or use default code (use YADDA_DEFAULT_SCRIPTS).
  state.defineSyncedProperty 'configCodeSource', CODE_SOURCE_BUILTIN, true

  # every single file has a different property
  YADDA_DEFAULT_SCRIPT_NAMES.forEach (name) ->
    prop = _getCodePropName(name)
    state.defineSyncedProperty prop, YADDA_DEFAULT_SCRIPTS[name]
    state.remote.setDefault prop, YADDA_DEFAULT_SCRIPTS[name]

  _getCodeFragment = (basename) ->
    src = state.configCodeSource
    coffeeCode = ''
    prop = _getCodePropName(basename)
    if src == CODE_SOURCE_REMOTE
      coffeeCode = state.remote[prop]
    else if src == CODE_SOURCE_LOCAL
      coffeeCode = state[prop]
    if !_.isString(coffeeCode) || coffeeCode.length == 0
      coffeeCode = YADDA_DEFAULT_SCRIPTS[basename]
    coffeeCode

  request = (path, data, callback, onError) ->
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
  _compileCache = {}
  _coffeeCompile = (code, cacheKey) -> # like CoffeeScript.compile, but uses cache
    if _compileCache[cacheKey]?[0] == code
      _compileCache[cacheKey][1]
    else
      coffee = CoffeeScript.compile(code)
      _compileCache[cacheKey] = [code, coffee]
      coffee
  _cached = {}
  _execute = (code) -> # execute javascript code, return [scope, error]
    if _cached.code != code
      _cached.code = code
      try
        scope = {}
        eval "(function() { #{code} }).call(scope);"
        _cached.err = null
      catch err
        if __DEV__
          window.execErr = err
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
          if confirm('Restored to built-in UI. Do you also want to discard customized script stored in localStorage?')
            for name, code of YADDA_DEFAULT_SCRIPTS
              state[_getCodePropName(name)] = code
            state.configCodeSource = CODE_SOURCE_LOCAL
      else if src == CODE_SOURCE_REMOTE
        furtherRestore = ->
          if confirm('Restored to built-in UI. Do you also want to discard customized script stored in Phabricator server?')
            for name, code of YADDA_DEFAULT_SCRIPTS
              state.remote[_getCodePropName(name)] = code
            state.configCodeSource = CODE_SOURCE_REMOTE
            state.remote.scheduleSync()
      if furtherRestore
        setTimeout furtherRestore, 500

    render: ->
      fullCode = ''
      content = null
      errors = []
      YADDA_DEFAULT_SCRIPT_NAMES.forEach (name) ->
        frag = _getCodeFragment(name)
        try
          # compile fragments individually so the line number in error is correct
          fullCode += _coffeeCompile(frag, name)
        catch err
          errors.push err
      [scope, err] = _execute(fullCode)
      if err
        errors.push err

      resetInfo =
        div className: 'phui-info-view phui-info-severity-notice grouped',
          'You can reset to the default UI, and optionally discard customized script to resolve issues.'
          div className: 'phui-info-view-actions',
            button className: 'phui-button-default', onClick: @handleCodeReset, 'Reset UI'

      if __DEV__
        window.errors = errors

      if errors.length == 0
        if !_.isUndefined(scope.render)
          try
            content = scope.render(state)
          catch err
            errors.push err
        else
          return div null,
            div className: 'phui-info-view phui-info-severity-notice',
              'render(state) needs to be defined. For example:'
              pre style: {padding: 8, marginTop: 8, backgroundColor: '#EBECEE', overflow: 'auto'},
                '@render = (state) ->\n'
                '  state.revisions.map (r) ->\n'
                '    a style: {display: "block"}, href: "/D#{r.id}", r.title'
            resetInfo

      div null,
        errors.map (e, i) ->
          div key: i, className: 'phui-info-view phui-info-severity-warning',
            e.toString()
            if e.stack
              pre style: {padding: 8, marginTop: 8, backgroundColor: '#EBECEE', overflow: 'auto'},
                e.stack
        if errors.length > 0
          resetInfo
        content
        # bottom-left triangle
        if state.configCodeSource != CODE_SOURCE_BUILTIN
          span className: 'hint-code-different', onDoubleClick: @handleCodeReset, title: 'The code rendering this page has been customized. If anything breaks, double click to restore to the built-in version.'

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
      request '/api/yadda.setstate', data: remote.toJSON(), ((r) -> r.error_info && showError(r.error_info)), showError
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
        _applyNewRemote remote
      redraw()

    if initial.state
      _processResult initial.state
    else
      request '/api/yadda.query', null, (r) ->
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
      {name, code} = e.data.value
      if src == CODE_SOURCE_BUILTIN
        if code == YADDA_DEFAULT_SCRIPTS[name]
          return
        # CODE_SOURCE_BUILTIN is immutable. Change to "remote" automatically.
        state.configCodeSource = src = CODE_SOURCE_REMOTE
      prop = _getCodePropName(name)
      if src == CODE_SOURCE_LOCAL
        state[prop] = code
      else if src == CODE_SOURCE_REMOTE
        state.remote[prop] = code
        state.remote.scheduleSync()
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
    <title>Yadda Interface Editor</title>
    <style>html, body, div { padding: 0; margin: 0; overflow: hidden; }
      div.yadda-editor { position: absolute; top: 28px; right: 0; bottom: 0; left: 0; width: 100%; }
      textarea.yadda-editor { width: 100%; height: 100%; }
      .filename-tab-bar { background: #DFE0E2; padding-left: 60px; font-family: Arial; font-size: 13px; line-height: 20px; height: 28px; }
      .filename-tab { padding: 4px 8px; box-sizing: border-box; cursor: pointer; display: inline-block; border-left: 1px solid rgba(255,255,255,0.5); }
    </style>
    <style class="dynamic-tab"></style>
    '''
    # Execute javascript in that window by "_editorWin.eval" so closing this
    # window won't cause event listeners etc. to lose for that window.
    runScript = (coffee) -> _editorWin.eval CoffeeScript.compile(coffee)
    runScript """
      markAsDisconnect = -> document.title = '(Disconnected)'
      checkAlive = ->
        if !_parent || _parent.closed
          markAsDisconnect()
      setInterval checkAlive, 1000
      """

    # File selectors
    doc.body.innerHTML = """
      <div class="filename-tab-bar">
        #{_.join(YADDA_DEFAULT_SCRIPT_NAMES.map((k) -> "<span class='filename-tab #{k}' data-filename='#{k}'>#{k}</span>"), '')}
      </div>
      <div class="yadda-editor">
      </div>
      """
    runScript """
      codeMap = {}
      defaultCodeMap = {}
      selectedTab = 'entry'
      updateDynamicStylesheet = ->
        css = ".filename-tab.\#{selectedTab} { background: white; }"
        for name, code of defaultCodeMap
          if codeMap[name] != defaultCodeMap[name] && codeMap[name].length > 0
            css += ".filename-tab.\#{name} { font-weight: bold; }"
        document.head.querySelector('style.dynamic-tab').innerHTML = css
      postCode = () ->
        name = selectedTab
        code = codeMap[selectedTab]
        if !code || code == ''
          code = defaultCodeMap[selectedTab]
        _parent.postMessage({'type': 'code-change', 'value': {name, code}}, #{JSON.stringify(window.location.origin)})
      window.settingEditorCode = false
      window.syncFromEditorCode = (code) ->
        if window.settingEditorCode
          return
        # sync from editor -> other window
        if codeMap[selectedTab] != code
          codeMap[selectedTab] = code
          postCode()
        updateDynamicStylesheet()
      window.switchTab = (name) ->
        if name
          selectedTab = name
        code = codeMap[selectedTab]
        if !code || code == ''
          code = defaultCodeMap[selectedTab]
        # setEditorCode is defined below
        window.setEditorCode code
        updateDynamicStylesheet()
        document.title = "Yadda Interface Editor - \#{selectedTab}"
      window.setInitialCode = (name, code) -> codeMap[name] = code
      window.setDefaultCode = (name, code) -> defaultCodeMap[name] = code
      document.querySelector('.filename-tab-bar').addEventListener 'click', (e) ->
        t = e.target
        if t && t.dataset.filename
          window.switchTab t.dataset.filename
      """

    # Editor could have different implementation: ACE or textarea
    for k, v of YADDA_DEFAULT_SCRIPTS
      _editorWin.setInitialCode k, _getCodeFragment(k)
      _editorWin.setDefaultCode k, v

    useTextarea = ->
      doc.body.querySelector('.yadda-editor').innerHTML = """
        <textarea class="yadda-editor" spellcheck="false" wrap="soft" style="border: none; resize: none; white-space: pre;"></textarea>
        """
      runScript """
        editor = document.querySelector('textarea.yadda-editor')
        editor.addEventListener 'input', (e) ->
          syncFromEditorCode e.target.value
        window.setEditorCode = (code) ->
          window.settingEditorCode = true
          document.querySelector('textarea.yadda-editor').value = code
          window.settingEditorCode = false
        window.switchTab()
        """

    useAce = ->
      runScript """
        editor = ace.edit document.querySelector('.yadda-editor')
        editor.getSession().setOptions tabSize: 2, useSoftTabs: true
        editor.getSession().setMode 'ace/mode/coffee'
        editor.setSelectionStyle 'text'
        editor.setShowPrintMargin false
        editor.getSession().on 'change', (e) -> syncFromEditorCode editor.getValue()
        emptySelection = editor.selection.getRange()
        window.setEditorCode = (code) ->
          window.settingEditorCode = true
          session = editor.getSession()
          session.setValue(code)
          session.selection.setRange(emptySelection) # move to top
          window.settingEditorCode = false
        window.editor = editor
        window.switchTab()
        """

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
    window.YADDA_DEFAULT_SCRIPTS = YADDA_DEFAULT_SCRIPTS
    window.state = state

document.addEventListener 'DOMContentLoaded', _init
