{a, br, button, code, div, hr, h1, input, kbd, li, optgroup, option, p, progress, select, span, strong, style, table, tbody, td, th, thead, tr, ul} = React.DOM
{markNux, renderPreview, renderReply} = this

@renderDialog = (state) ->
  name = state.dialog
  if !name
    return
  [
    div className: 'jx-mask', key: '1'
    div className: "jx-client-dialog dialog-#{name}", key: '2',
      div className: "aphront-dialog-view aphront-dialog-view-standalone dialog-#{name}",
        div className: 'aphront-dialog-head',
          div className: 'phui-header-shell',
            h1 className: 'phui-header-header', _.capitalize(name)
        if name == 'settings'
          renderSettings state
        else if name == 'preview'
          renderPreview state, state.currRevs
        else if name == 'reply'
          renderReply state, state.currRevs
  ]

renderConfigItem = (name, description, children...) ->
  div className: 'config-item',
    if description
      div className: 'config-desc', description
    div className: 'config-oneline-pair grouped',
      div className: 'config-name', name
      children...

renderBooleanConfig = (state, name, variable, description, yesName = 'Yes', noName = 'No') ->
  val = state[variable]
  handleChange = (e) ->
    isYes = (e.target.value == 'Y')
    state[variable] = isYes
    e.target.blur()
  renderConfigItem name, description, select className: 'config-value config-boolean', onChange: ((e) -> handleChange(e)), value: val && 'Y' || 'N',
    option value: 'Y', yesName
    option value: 'N', noName

renderFilterPresets = (state) ->
  active = state.activeFilter
  presets = state.presets
  handlePresentSave = (i, e) ->
    presets = state.presets
    if e.ctrlKey || e.altKey
      delete presets["#{i}"]
    else
      presets["#{i}"] = _.clone(state.activeFilter)
    state.presets = presets
  renderConfigItem 'Filter Presets', 'Click numbers below to save the current filter selection as presets. Then they can be quickly activated by pressing corresponding number keys.',
    span className: 'config-value phui-button-bar',
      [1..6].map (i) ->
        preset = presets["#{i}"]
        if _.isEqual(active, preset)
          className = 'button-green'
        else if preset
          className = ''
        else
          className = 'button-grey'
        if i == 1
          className += ' phui-button-bar-first'
        else if i == 6
          className += ' phui-button-bar-last'
        else
          className += ' phui-button-bar-middle'
        title = _.join(_.flatten(_.values(preset)), "\n")
        button {className, title, key: i, onClick: (e) -> handlePresentSave(i, e)}, i

renderCodeSourceSelector = (state) ->
  renderConfigItem 'Interface Script', 'Advanced customization (ex. add a shortcut key to enable a custom filter checking keywords in comments) can be achieved by editing the script rendering Yadda UI.',
    span className: 'config-value',
      select onChange: ((e) -> state.configCodeSource = e.target.value; e.target.blur(); markNux state, 'code-switch'), value: state.configCodeSource,
        option value: CODE_SOURCE_BUILTIN, 'Not Customized (Use Built-in)'
        option value: CODE_SOURCE_LOCAL, 'Customized (Sync with localStorage)'
        if state.user
          option value: CODE_SOURCE_REMOTE, 'Customized (Sync with Phabricator)'
    span className: 'config-value', style: {marginLeft: 16},
      a onClick: (-> triggerShortcutKey('~')), 'Edit'

renderConfigReset = (state) ->
  handleReset = ->
    if confirm('This will restore some config options to default values. Do you want to continue?')
      # reset local state
      state.activeFilter = {}
      # reset remote state
      toRemove = ['readNux', 'presets']
      for k, v of state.remote
        if _.startsWith(k, 'config')
          toRemove.push(k)
      for k in toRemove
        delete state.remote[k]
      state.remote.scheduleSync()
  renderConfigItem 'Reset', 'Restore config options to default values and make hints appear again. Stored customized scripts won\'t be discarded.',
    span className: 'config-value',
      button className: 'button-red small', onClick: handleReset, 'Reset'

renderSettings = (state) ->
  div null,
    div className: 'config-list', style: {margin: 16},
      renderBooleanConfig state, 'Series Display', 'configFullSeries', 'If D1 and D2 belong to a same series, and D1 is filtered out but not D2. This controls whether D1 is visible or not.', 'Show Entire Series', 'Show Only Individual Revisions'
      renderBooleanConfig state, 'Archive on Open', 'configArchiveOnOpen', 'Archive revisions being opened. Useful if you want to see a patch only once.', 'Enable Archive on Open', 'Disable Archive on Open'
      renderFilterPresets state
      renderCodeSourceSelector state
      renderConfigReset state
    div className: 'aphront-dialog-tail grouped',
      button className: 'button-grey', onClick: (-> state.dialog = null), 'Close'
