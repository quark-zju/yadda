###*
# @provides yadda-home
# @requires codemirror
# @requires codemirror-coffeescript
# @requires coffeescript
# @requires lodash
# @requires moment
# @requires react
# @requires react-dom
###

_codeKey = 'yaddaCode'
_profileKey = 'prof'
_redraw = -> return

state =
  revisions: []
  profileMap: {}
  set: (name, value) ->
    if name
      state[name] = value
    _redraw()

_codemirrorOpts =
  mode: 'coffeescript'
  lineNumbers: true
  tabSize: 2
  indentWithTabs: false
  lineNumbers: true

_init = ->
  {div, pre} = React.DOM

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
    if _cached.code != state.code
      try
        bare = CoffeeScript.compile(state.code, bare: true)
        scope = {}
        code = "(function() { #{bare} }).call(scope);"
        eval code
        _cached.code = state.code
        if state.code != yaddaDefaultCode
          localStorage[_codeKey] = state.code
      catch err
        if __DEV__
          window.err = err
      _cached.scope = scope
    return [(_cached.scope || {}), err]

  class Root extends React.Component
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

  state.code = (localStorage[_codeKey] || yaddaDefaultCode).replace(/\t/g, '  ')
  element = React.createElement(Root)
  node = ReactDOM.render element, document.querySelector('.yadda-root')
  _redraw = -> node.forceUpdate()

  refresh = ->
    _request '/api/yadda.query', null, (r) ->
      if r.result
        state.revisions = r.result.revisions
        state.profileMap = _.keyBy(r.result.profiles, (p) -> p.userName)
        _redraw()

  refresh()
  setInterval refresh, 150000

  initEditor = (target) ->
    target.style.left = '30px'
    target.style.bottom = '30px'
    target.style.width = '500px'
    target.style.height = "#{window.innerHeight * 3 / 5}px"
    editorOpts = _.extend({value: state.code}, _codemirrorOpts)
    editor = CodeMirror target, editorOpts
    editor.on 'change', (editor) =>
      state.set 'code', editor.getValue().replace(/\t/g, '  ')
    initEditor = -> return # no need to init again

  if JX.KeyboardShortcut
    k = new JX.KeyboardShortcut(['~'], 'Show live code editor.')
    k.setHandler ->
      target = document.querySelector('.yadda-editor')
      if target.style.display == 'none'
        target.style.display = ''
        initEditor target
      else
        target.style.display = 'none'
    k.register()

  if __DEV__
    window.state = state
    window._cached = _cached

document.addEventListener 'DOMContentLoaded', _init
