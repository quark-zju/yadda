# This is a live CoffeeScript editor affecting the Yadda interface.
# Code change will be sent to the main Yadda page which saves it to either
# localStorage or Phabricator server depending on configuration.
#
# The entry point is "@render(state)" which returns ReactElement. See
# /conduit/method/yadda.query for what "state" look like. The "yadda.query"
# query will be called to update "state" periodically in background.
#
# The entire script is split into smaller parts in different tabs. Check
# the "filters" tab, and try change something there.
#
# To restore a tab to default script, just delete all text there.
#
# Javascript libraries LoDash, Moment.js, React.js and Javelin are available.

{div, p, progress} = React.DOM
{renderMainPage, showNux, sortKeyFunctions} = this

# Main entry point
@render = (state) ->
  # Make it easier for debugging using F12 developer tools
  window.state = state

  if not state.revisions
    renderLoadingIndicator(state)
  else
    normalizeState state
    renderMainPage state

renderLoadingIndicator = (state) ->
  if state.error
    div className: 'phui-info-view phui-info-severity-error',
      state.error
  else
    div style: {textAlign: 'center', marginTop: 240, color: '#92969D'},
      p null, 'Fetching data...'
      progress style: {height: 10, width: 100}

# State initialization
normalizeState = (state) ->
  storeLocally = state.defineSyncedProperty
  if state.user
    storeRemotely = (name, fallback) -> state.defineSyncedProperty(name, fallback, true)
  else
    # Not logged-in, cannot store anything remotely
    storeRemotely = storeLocally
  if not state.activeFilter
    storeLocally 'activeFilter', {}
  if _.isUndefined(state.presets)
    storeRemotely 'presets', {}
  if not state.activeSortKey
    storeLocally 'activeSortKey', sortKeyFunctions[0][0]
  if not state.activeSortDirection
    storeLocally 'activeSortDirection', -1
  if not state.currRevs
    storeLocally 'currRevs', []
  if not state.readMap
    storeRemotely 'readMap', {}
  if not state.checked
    storeLocally 'checked', {}
  if not state.readNux
    storeRemotely 'readNux', {}
  if _.isUndefined(state.dialog)
    storeLocally 'dialog', null
    JX.Stratcom.listen 'keydown', null, (e) ->
      if e.getSpecialKey() == 'esc' && state.dialog != null
        state.dialog = null
        e.prevent()
  if _.isUndefined(state.configFullSeries)
    storeRemotely 'configFullSeries', true
  if _.isUndefined(state.configArchiveOnOpen)
    storeRemotely 'configArchiveOnOpen', false
  if !_.isUndefined(state.remote.code) && state.configCodeSource == CODE_SOURCE_BUILTIN
    showNux state, 'code-switch', 'Hint: If you are looking for your own customized script about Yadda UI, go to "Settings", change "Interface Script" option, and then click "Edit".'
