# Keyboard shortcuts

{MUTE_DATE, markAsRead, markNux, openRevisions, scrollIntoView} = this

_lastIndex = -1

@installKeyboardShortcuts = (state, grevs, revs, topoSort) ->
  toId = (r) -> r.id
  getRevIds = (singleSelection) ->
    if singleSelection
      _.flatten(_.values(grevs)).map((r) -> [r.id])
    else
      _.values(grevs).map((rs) -> rs.map(toId))
  getIndex = (revIds) ->
    currRevs = state.currRevs || []
    index = _.findIndex(revIds, (rs) -> _.intersection(rs, currRevs).length > 0)
    if index == -1
      index = _.min([revIds.length - 1, _lastIndex]) # best-effort guess when things got deleted
    _lastIndex = index
  focusNext = (revIds) ->
      i = getIndex(revIds)
      state.currRevs = revIds[_.min([i + 1, revIds.length - 1])] || []
      scrollIntoView('td.selected')
  focusPrev = (revIds) ->
      i = getIndex(revIds)
      state.currRevs = revIds[_.max([i - 1, 0])] || []
      scrollIntoView('td.selected')

  shortcutKey ['j'], 'Focus on revisions of the next series.', -> focusNext(getRevIds(false))
  shortcutKey ['k'], 'Focus on revisions of the previous series.', -> focusPrev(getRevIds(false))
  shortcutKey ['J'], 'Focus on the next single revision.', -> focusNext(getRevIds(true))
  shortcutKey ['K'], 'Focus on the previous single revision.', -> focusPrev(getRevIds(true))
  shortcutKey ['*'], 'Focus on all revisions in the current view.', -> state.currRevs = _.flatten(_.values(grevs)).map(toId)

  shortcutKey ['x'], 'Toggle selection for focused revisions.', ->
    checked = state.checked
    value = not ((state.currRevs || []).some (r) -> checked[r])
    (state.currRevs || []).forEach (r) -> checked[r] = value
    state.checked = checked

  copyIds = (ids) ->
    text = _.join(topoSort(ids).map((id) -> "D#{id}"), '+')
    if not text
      return
    copy(text)
    notify("Copied: #{text}")

  shortcutKey ['c'], 'Copy focused revision numbers to clipboard (useful for phabread).', -> copyIds(state.currRevs || [])
  shortcutKey ['C'], 'Copy selected revision numbers to clipboard.', -> copyIds(_.keys(_.pickBy(state.checked)))

  shortcutKey ['f'], 'Remove filtered out revisions from focus', ->
    revIds = _.keyBy(revs, (r) -> r.id)
    state.currRevs = state.currRevs.filter((r) -> revIds[r])
    markNux state, 'grey-rev'

  shortcutKey ['o'], 'Open one of focused revisions in a new tab.', ->
    r = _.min(state.currRevs)
    if r
      openRevisions state, [r]
  shortcutKey ['O'], 'Open all of focused revisions in new tabs.', ->
    openRevisions state, state.currRevs

  shortcutKey ['a'], 'Archive selected revisions (mark as no new updates).', -> markAsRead state
  shortcutKey ['m'], 'Mute selected revisions (mark as no updates forever).', -> markAsRead state, MUTE_DATE
  shortcutKey ['U'], 'Mark selected revisions as unread (if last activity is not by you).', -> markAsRead state, 0

  shortcutKey ['s'], 'Toggle full series display.', ->
    markNux state, 'grey-rev'
    state.configFullSeries = !state.configFullSeries

  # Refresh only works for logged-in user. Since otherwise there is no valid CSRF token for Conduit API.
  if state.user
    shortcutKey ['r'], 'Fetch updates from server immediately.', refresh

  # Filter Presets
  [1..6].forEach (ch) ->
    shortcutKey ["#{ch}"], "Load filter preset #{ch}", ->
      state.activeFilter = state.presets["#{ch}"] || {}
