###*
# @provides yadda-home
# @requires coffeescript
# @requires lodash
# @requires moment
# @requires react
# @requires react-dom
###

_codeKey = 'yaddaCode'
_profileKey = 'prof'
redraw = -> return

state =
  # define a property that syncs from localStorage
  defineSyncedProperty: (name, fallback=null) ->
    if _.isString(fallback)
      loads = dumps = (x) -> x
    else
      loads = JSON.parse
      dumps = JSON.stringify
    Object.defineProperty state, name,
      enumerable: false, configurable: false
      get: ->
        try
          return loads(localStorage[name]) || fallback
        fallback
      set: (v) ->
        if v == fallback
          localStorage.removeItem name
        else
          localStorage[name] = dumps(v)
        redraw()

_init = ->
  state.defineSyncedProperty 'code', yaddaDefaultCode

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
    handleCodeRest: ->
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
          span className: 'hint-code-different', onDoubleClick: @handleCodeRest, title: 'The code driven this page has been changed so it is different from the default. If that is not intentionally, double click to restore to the default code.', '* customized'

  element = React.createElement(Root)
  node = ReactDOM.render element, document.querySelector('.yadda-root')
  redraw = -> node.forceUpdate()

  refresh = ->
    _request '/api/yadda.query', null, (r) ->
      if r.result
        state.revisions = r.result.revisions
        state.user = r.result.user
        state.profileMap = _.keyBy(r.result.profiles, (p) -> p.userName)
        state.updatedAt = moment()
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
      new JX.Notification().setContent('The editor window was open.').setDuration(3000).show()
      return
    _editorWin = window.open('', '', 'width=600,height=800')
    _editorWin._parent = window
    doc = _editorWin.document
    doc.head.innerHTML = '''
    <title>Yadda Live Editor</title>
    <style>html, body { padding: 0; margin: 0; overflow: hidden; }</style>
    '''
    doc.body.innerHTML = """
    <textarea class="editor" spellcheck="false" wrap="soft" style="height: 100%; width: 100%; border: none; resize: none; white-space: pre;"></textarea>
    """
    # Execute javascript in that window by setting its body content directly,
    # so closing this window won't cause event listeners etc. to lose for that
    # window.
    _editorWin.eval CoffeeScript.compile("""
    editor = document.querySelector('.editor')
    markAsDisconnect = ->
      editor.readOnly = true
      editor.style.backgroundColor = '#f7e2d4'
      document.title = '(Disconnected)'
    checkAlive = ->
      if !_parent || _parent.closed
        markAsDisconnect()
    setInterval checkAlive, 1000
    editor.addEventListener 'input', (e) ->
      _parent.postMessage({'type': 'code-change', 'value': e.target.value.replace(/\t/g, '  ')}, #{JSON.stringify(window.location.origin)})
    window.setCode = (code) ->
      document.querySelector('.editor').value = code
    """)
    _editorWin.setCode state.code || yaddaDefaultCode

  # The only way to access the editor is the "~" key.
  if JX.KeyboardShortcut
    k = new JX.KeyboardShortcut(['~'], 'Pop-up live code editor.')
    k.setHandler popupEditor
    k.register()

  if __DEV__
    window.state = state
    window._cached = _cached

document.addEventListener 'DOMContentLoaded', _init
