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
    Object.defineProperty state, name,
      enumerable: false, configurable: false
      get: ->
        try
          return JSON.parse(localStorage[name]) || fallback
        fallback
      set: (v) ->
        if v == fallback
          localStorage.removeItem name
        else
          localStorage[name] = JSON.stringify(v)
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

  _cached = {}
  _compile = -> # compile state.code, return [scope, error]
    code = state.code
    if _cached.code != code
      try
        bare = CoffeeScript.compile(code, bare: true)
        scope = {}
        code = "(function() { #{bare} }).call(scope);"
        eval code
        _cached.code = code
      catch err
        if __DEV__
          window.err = err
      _cached.scope = scope
    return [(_cached.scope || {}), err]

  {div, span} = React.DOM
  class Root extends React.Component
    handleCodeRest: ->
      if confirm('Do you want to reset to the default code? This cannot be undone.')
        state.code = yaddaDefaultCode

    render: ->
      content = null
      errors = []
      [scope, err] = _compile()
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
        if state.code && state.code != yaddaDefaultCode
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

  _editorWin = null
  initEditor = ->
    if not _editorWin || _editorWin.closed
      _editorWin = window.open('', '', 'width=400,height=700')
    doc = _editorWin.document
    doc.head.innerHTML = '''
    <title>Yadda Editor</title>
    '''
    doc.body.innerHTML = '<textarea class="editor" spellcheck="false" style="height: 100%; width: 100%;"></textarea>'
    target = doc.querySelector '.editor'
    target.value = state.code || yaddaDefaultCode
    target.addEventListener 'input', (e) ->
      state.code = e.target.value.replace(/\t/g, '  ')

  if JX.KeyboardShortcut
    k = new JX.KeyboardShortcut(['~'], 'Pop-up live code editor.')
    k.setHandler initEditor
    k.register()

  if __DEV__
    window.state = state
    window._cached = _cached

document.addEventListener 'DOMContentLoaded', _init
