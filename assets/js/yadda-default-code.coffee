# This is a live CoffeeScript editor affecting the Yadda interface.
# Code change will be sent to the main Yadda page which saves it to either
# localStorage or Phabricator server depending on configuration.
#
# The entry point is "@render(state)" which returns ReactElement. The most
# interesting information is "state.revisions". See /conduit/method/yadda.query
# for what "state.revisions" look like. The "yadda.query" query will be called
# to update "state" periodically.
#
# Javascript libraries LoDash, Moment.js, React.js and Javelin are available.

# Pre-defined filters
# Change this to affect the navigation side bar
getFilterGroups = (state, getStatus) ->
  # If "getStatus" is not passed, filter functions are incorrect, but titles
  # are okay.
  readMap = state.readMap

  # Filter actions - return actions since last code update
  afterUpdateActions = (r) ->
    mtime = getDateCodeUpdated(r)
    r.actions.filter((t) -> parseInt(t.dateModified) > mtime)

  # [name, filterFunc]
  reviewFilters = [
    ['Needs 1st Pass', (revs) -> revs.filter (r) -> getStatus(r.id).accepts.length == 0 && getStatus(r.id).rejects.length == 0]
    ['Needs 2nd Pass', (revs) -> revs.filter (r) -> getStatus(r.id).accepts.length > 0]
    ['Needs Revision', (revs) -> revs.filter (r) -> getStatus(r.id).rejects.length > 0]
  ]

  # logged-in user has more filters
  peopleFilters = []
  if state.user
    peopleFilters = [
      ['Authored By Others', (revs) -> revs.filter (r) -> r.author != state.user]
      ['Authored By Me', (revs) -> revs.filter (r) -> r.author == state.user]
      ['Subscribed By Me', (revs) -> revs.filter (r) -> r.ccs.includes(state.user)]
    ]

  updateFilters = [
    ['Has Any Updates', (revs) -> revs.filter (r) -> getDateModified(r) > getDateRead(state, readMap, r)]
    ['Has Code Updates', (revs) -> revs.filter (r) -> getDateCodeUpdated(r) > getDateRead(state, readMap, r)]
    ['Already Read', (revs) -> revs.filter (r) -> t = getDateRead(state, readMap, r); getDateModified(r) <= t && t != _muteDate]
  ]

  repos = _.uniq(state.revisions.map((r) -> r.callsign || 'Unnamed'))
  repos = _.sortBy(repos, (r) -> [r == 'Unnamed', r.length, r])
  repoFilters = repos.map (repo) -> [repo, (revs) -> revs.filter (r) -> r.callsign == repo || (!r.callsign && repo == 'Unnamed')]

  # [(group title, [(name, filterFunc)])]
  [
    ['Review Stages', reviewFilters]
    ['People', peopleFilters]
    ['Read States', updateFilters]
    ['Repositories', repoFilters]
  ]

sortKeyFunctions = [
  ['updated', (revs, state) -> _.max(revs.map (r) -> getDateModified(r))]
  ['created', (revs, state) -> _.min(revs.map (r) -> parseInt(r.dateCreated))]
  ['author', (revs, state) -> _.min(revs.map (r) -> [r.author, parseInt(r.id)])]
  ['title', (revs, state) -> _.min(revs.map (r) -> r.title)]
  ['stack size', (revs, state) -> revs.length]
  ['activity count', (revs, state) -> _.sum(revs.map (r) -> r.actions.filter((x) -> parseInt(x.dateCreated) > parseInt(r.dateCreated)).length)]
  ['phabricator status', (revs, state) -> _.sortedUniq(revs.map (r) -> r.status)]
  ['line count', (revs, state) -> _.sum(revs.map (r) -> parseInt(r.lineCount))]
]

# Use selected query and repo to filter revisions
filterRevs = (state, getStatus) ->
  revs = state.revisions
  active = state.activeFilter
  getFilterGroups(state, getStatus).map ([title, filters]) ->
    selected = getSelectedFilters(active, title, filters)
    subrevs = null
    filters.forEach ([name, func]) ->
      if selected[name]
        if subrevs == null
          subrevs = func(revs, state)
        else
          subrevs = _.uniqBy(subrevs.concat(func(revs, state)), (r) -> r.id)
    if subrevs != null
      revs = subrevs
  revs

# Generate utilities for topology sorting. Return 2 functions:
# - getSeriesId: revId -> seriesId
# - topoSort: revs -> sortedRevs
getTopoSorter = (allRevs) ->
  byId = _.keyBy(allRevs, (r) -> r.id)
  getSeriesId = _.memoize((revId) ->
    _.min(byId[revId].dependsOn.map((i) -> getSeriesId(i))) || revId)
  getSeriesIdChain = _.memoize((revId) ->
    depends = byId[revId].dependsOn
    _.join(_.concat(depends.map(getSeriesIdChain), [_.padStart(revId, 8)])))
  topoSort = (revsOrIds) ->
    if revsOrIds.some((x) -> !x.id)
      _.sortBy(revsOrIds, (id) -> getSeriesIdChain(id))
    else
      _.sortBy(revsOrIds, (r) -> getSeriesIdChain(r.id))
  [getSeriesId, topoSort]


# Given a list of actions, return a function:
# - isSeriesAction: (action) -> true | false
_seriesRe = /\bth(e|is) series\b/i
getIsSeriesAction = (actions) ->
  seriesDates = {} # {dateCreated: true}
  actions.forEach (x) ->
    if x.comment && _seriesRe.exec(x.comment)
      seriesDates[x.dateCreated] = true
  (action) -> seriesDates[action.dateCreated] || false

# Normalize action type (ex. 'plan-changes' -> 'reject') and only return those
# we care about: accept, update, request-review, reject.
sensibleActionType = (action) ->
  if action.type == 'plan-changes'
    'reject'
  else if _.includes(['accept', 'update', 'request-review', 'reject'], action.type)
    action.type

# Return a function:
# - getStatus: (revId) -> {accepts: [user], rejects: [user]}
# Update state.readMap according to series commented status
# Re-calculate revision statuses using 'actions' data.
# - Set '_status: {accept: [username], reject: [username]}'
#   - accept is sticky
#   - reject is not sticky
#   - 'request-review'
#   - 'plan-changes' is seen as 'rejected'
#   - SPECIAL: comment with "this series" applies to every patches in the
#     series
# - Do not take Phabricator review status into consideration. This bypasses
#   blocking reviewers, non-sticky setting and unknown statuses.
getStatusCalculator = (state, getSeriesId) ->
  revs = state.revisions
  readMap = state.readMap
  byId = _.keyBy(revs, (r) -> r.id)

  seriesDateRead = {} # {seriesId: int}
  seriesActions = {} # {seriesId: [('accept' | 'reject', action, revId)]}
  revActions = {} # {revId: [('accept' | 'reject' | 'update', action, revId)]}

  # populate above internal states
  revs.forEach (r) ->
    seriesId = getSeriesId(r.id)
    isSeriesAction = getIsSeriesAction(r.actions)
    r.actions.forEach (x) ->
      ctime = parseInt(x.dateCreated)
      author = x.author
      verb = sensibleActionType(x)
      isSeries = isSeriesAction(x)
      if isSeries && author == state.user
        seriesDateRead[seriesId] ||= 0
        seriesDateRead[seriesId] = _.max([seriesDateRead[seriesId], ctime])
      if verb
        if isSeries
          # a series action
          (seriesActions[seriesId] ||= []).push [verb, x, r.id]
        else
          # a single revision action
          (revActions[r.id] ||= []).push [verb, x, r.id]

  # update readMap
  readMapChanged = false
  revs.forEach (r) ->
    stime = seriesDateRead[getSeriesId(r.id)]
    if stime
      atime = getDateRead(state, readMap, r)
      if atime < stime
        readMap[r.id] = stime
        readMapChanged = true
  if readMapChanged
    state.readMap = readMap

  # return {'accept': [unixname], 'reject': [unixname]}
  _.memoize (revId) ->
    seriesId = getSeriesId(revId)
    accepts = []
    rejects = []
    # combine normal actions and series actions
    actions = (seriesActions[seriesId] || []).concat(revActions[revId])
    _.sortBy(actions, ([verb, x, rId]) -> parseInt(x.dateCreated)).forEach ([verb, x, rId]) ->
      if verb == 'request-review'
        accepts = []
        rejects = []
      else if verb == 'update'
        rejects = []
      else if verb == 'accept'
        accepts.push([rId, x])
      else if verb == 'reject'
        accepts = []
        rejects.push([rId, x])
    {accepts: accepts, rejects: rejects}

# Group by series for selected revs and sort them
groupRevs = (state, revs, getSeriesId, topoSort) -> # [rev] -> [[rev]]
  allRevs = state.revisions
  # {seriesId: [rev]}
  sortRevsByDep = _.groupBy(revs, (r) -> getSeriesId(r.id))
  # config: do we always include entire series even if only few revs are picked
  if state.configFullSeries # include full series
    showRevsByDep = _.groupBy(allRevs, (r) -> getSeriesId(r.id))
  else # do not include full series
    showRevsByDep = sortRevsByDep
  # for series, use selected sort function
  entry = _.find(sortKeyFunctions, (q) -> q[0] == state.activeSortKey)
  groupSortKey = if entry then entry[1] else sortKeyFunctions[0][1]
  gsorted = _.sortBy(_.keys(sortRevsByDep), (d) -> groupSortKey(sortRevsByDep[d], state))
  if state.activeSortDirection == -1
    gsorted = _.reverse(gsorted)
  # within a series, sort by dependency topology
  gsorted.map (d) -> _.reverse(topoSort(showRevsByDep[d]))

# Mark as read - record dateModified
markAsRead = (state, markDate = null, revIds = null) ->
  if revIds == null
    revIds = _.keys(_.pickBy(state.checked))
  marked = state.readMap
  revMap = _.keyBy(state.revisions, (r) -> r.id)
  # remove closed revisions
  marked = _.pickBy(marked, (d, id) -> revMap[id])
  # update selected (revIds) entries
  revIds.forEach (id) ->
    if revMap[id]
      if markDate is null
        marked[id] = getDateModified(revMap[id])
      else if markDate == 0
        delete marked["#{id}"]
      else
        marked[id] = markDate
  state.readMap = marked
  state.checked = {}

# Get timestamp of last "marked read" or commented
getDateRead = (state, readMap, rev) ->
  commented = _.max(rev.actions.filter((x) -> x.author == state.user).map((x) -> parseInt(x.dateModified))) || -1
  marked = readMap[rev.id] || -1
  _.max([marked, commented])

# Get timestamp of the last action of given revision
getDateModified = (rev) ->
  # cannot use rev.dateModified since diff property update will bump that without generation a transaction/action
  _.max(rev.actions.map((x) -> parseInt(x.dateModified))) || -1

# Get timestamp of the last code update action
getDateCodeUpdated = (rev) ->
  _.max(rev.actions.map((t) -> t.type == 'update' && parseInt(t.dateModified) || -1)) || -1

# One-time normalize "state". Fill fields used by this script.
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

# Show NUX notification
_shownNux = {}
markNux = (state, type) ->
  readNux = state.readNux || {}
  if not readNux[type]
    readNux[type] = true
    state.readNux = readNux
showNux = (state, type, html, duration = null) ->
  if state.readNux[type] || _shownNux[type]
    return
  duration ||= (html.length * 50) + 5000
  node = JX.$H("<div>#{html}<br/><a class=\"got-it\">Got it</a></div>").getNode()
  gotIt = node.querySelector('a.got-it')
  gotIt.onclick = -> markNux state, type
  _shownNux[type] = true
  notify node, duration

# Make selected rows visible
scrollIntoView = (selector) ->
  isVisible = (e) ->
    top = e.getBoundingClientRect().top
    bottom = e.getBoundingClientRect().bottom
    top >= 0 && bottom <= window.innerHeight
  setTimeout((-> document.querySelectorAll(selector).forEach (e) ->
    if not isVisible(e)
      e.scrollIntoView()), 100)

# Open revisions in new tabs. Handles markAsRead.
openRevisions = (state, revIds) ->
  if state.configArchiveOnOpen
    markAsRead state, null, revIds
  revIds.forEach (r) -> window.open("/D#{r}", '_blank')

# Keyboard shortcuts
_lastIndex = -1
_muteDate = Number.MAX_SAFE_INTEGER
installKeyboardShortcuts = (state, grevs, revs, topoSort) ->
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
  shortcutKey ['m'], 'Mute selected revisions (mark as no updates forever).', -> markAsRead state, _muteDate
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

# Transaction to human readable text
describeAction = (action) ->
  # See "ACTIONKEY" under phabricator/src/applications/differential/xaction
  verb = {
    'inline': 'commented inline'
    'comment': 'commented'
    'update': 'updated the code'
    'accept': 'accepted'
    'reject': 'rejected'
    'close': 'closed the revision'
    'resign': 'resigned as reviewer'
    'abandon': 'abandoned the revision'
    'reclaim': 'reclaimed the revision'
    'reopen': 'reopened the revision'
    'plan-changes': 'planned changes'
    'request-review': 'requested review'
    'commandeer': 'commandeered the revision'
  }[action.type]
  if not verb
    return
  desc = "#{action.author} #{verb}"
  if action.comment
    if action.comment.includes('\n')
      desc += ": #{action.comment.split('\n')[0]}..."
    else
      desc += ": #{action.comment}"
  desc

# Change activeSortKey and activeSortDirection within the given cycle
cycleSortKeys = (state, sortKeys) ->
  i = _.indexOf(sortKeys, state.activeSortKey)
  if i == -1 || state.activeSortDirection != -1
    state.activeSortKey = sortKeys[(i + 1) % sortKeys.length]
    state.activeSortDirection = -1
  else
    state.activeSortDirection = 1

changeFilter = (state, title, name, multiple = false) ->
  active = state.activeFilter
  if _.isEqual(active[title], [name])
    active[title] = []
  else if not _.isArray(active[title]) or not multiple
    active[title] = [name]
    showNux state, 'multi-filter', 'Hint: Hold "Ctrl" and click to select (or remove) multiple filters.'
  else
    v = (active[title] ||= [])
    if _.includes(v, name)
      active[title] = _.without(v, name)
    else
      v.push(name)
    markNux state, 'multi-filter'
  state.activeFilter = active

getSelectedFilters = (activeFilter, title, filters) ->
  result = {}
  if _.isArray(activeFilter[title])
    activeFilter[title].forEach (f) -> result[f] = true
  else
    # pick the first one as default
    if filters.length > 0
      result[filters[0][0]] = true
  result

showDialog = (state, name) ->
  state.dialog = name
  scrollIntoView('.jx-client-dialog')

# React elements
{a, br, button, code, div, hr, h1, input, kbd, li, optgroup, option, p, progress, select, span, strong, style, table, tbody, td, th, thead, tr, ul} = React.DOM

renderFilterList = (state) ->
  active = state.activeFilter
  handleFilterClick = (e, title, name) ->
    changeFilter state, title, name, e.ctrlKey
    e.preventDefault()
    e.stopPropagation()

  getFilterGroups(state).map ([title, filters]) ->
    selected = getSelectedFilters(active, title, filters)
    if filters.length == 0
      return
    ul className: 'phui-list-view', key: title,
      li className: 'phui-list-item-view phui-list-item-type-label',
        span className: 'phui-list-item-name', title
      filters.map ([name, func], i) ->
        li key: name, className: "phui-list-item-view phui-list-item-type-link #{selected[name] and 'phui-list-item-selected'}",
          a className: 'phui-list-item-href', href: '#', onClick: ((e) -> handleFilterClick(e, title, name)),
            span className: 'phui-list-item-name', name

renderActionSelector = (state, className) ->
  active = state.activeFilter
  handleActionSelectorChange = (e) ->
    v = e.target.value
    if v[0] == 'F'
      [title, name] = JSON.parse(v[1..])
      changeFilter state, title, name
    else if v[0] == 'K'
      showNux state, 'key-help', 'Hint: Press <kbd>?</kbd> to view keyboard shortcuts. Some features are only accessible from keyboard.'
      triggerShortcutKey v[1..]
    e.target.blur()
  checked = _.keys(_.pickBy(state.checked))
  select className: "action-selector #{className}", onChange: handleActionSelectorChange, value: '+',
    option value: '+'
    if checked.length > 0
      optgroup label: "Action (#{checked.length} revision#{checked.length > 1 && 's' || ''})",
        option value: 'Ka', 'Archive'
        option value: 'Km', 'Mute'
        option value: 'KU', 'Mark Unread'
    getFilterGroups(state).map ([title, filters], j) ->
      if filters.length == 0
        return
      selected = getSelectedFilters(active, title, filters)
      optgroup className: 'filter', label: title, key: j,
        filters.map ([name, func], i) ->
          option key: i, disabled: selected[name], value: "F#{JSON.stringify([title, name])}", "#{name}#{selected[name] && ' (*)' || ''}"
    option value: 'K~', 'Interface Editor'

renderProfile = (state, username, opts = {}) ->
  profile = state.profileMap[username]
  a _.extend({className: "profile", title: profile.realName, href: "/p/#{username}", style: {backgroundImage: "url(#{profile.image})"}}, opts)

renderActivities = (state, rev, actions, extraClassName, handleLinkClick) ->
  author = className = title = actionId = ''
  elements = []
  append = ->
    if author
      elements.push renderProfile state, author, href: "/D#{rev.id}##{actionId}", onClick: handleLinkClick, title: title, className: "#{extraClassName} #{className} profile action", key: actionId
    author = className = title = actionId = ''
  isSeriesAction = getIsSeriesAction(actions)
  _.sortBy(actions, (x) -> parseInt(x.dateCreated)).forEach (x) ->
    if x.author != author
      append()
    author = x.author
    verb = sensibleActionType(x)
    if verb
      className = "#{verb} sensible-action" # the latest action wins
      if isSeriesAction(x)
        className += ' series'
    desc = describeAction(x)
    if desc
      title += "#{desc}\n"
    if !actionId or parseInt(x.id) < actionId
      actionId = parseInt(x.id)
  className += ' last'
  append()
  elements

renderReviewNux = (state) ->
  # Currently the Review NUX is HG specific
  active = state.activeFilter
  selected = {}
  getFilterGroups(state).map ([title, filters]) ->
    selected[title] = getSelectedFilters(active, title, filters)

  if !selected['Repositories']?['HG']
    return

  stage = _.findKey(selected['Review Stages'], (x) -> x)
  revId = 123 # example revId
  try
    revId = state.revisions[0].id
  if stage == 'Needs 1st Pass'
    nux = 'review-1p'
    help = div null,
      div className: 'mmb',
        '1st Pass is to make a preliminary decision - yes or no. Revisions without any decisions are listed here. Everyone is welcome to review them.'
      div className: 'mmb',
        'Explicit accepts or rejects help the review process more than just commenting. '
        'Code won\'t be pushed if they are only accepted in 1st Pass. So don\'t worry about immature decisions.'
      div className: '',
        'To express LGTM (or s/good/bad/) for an entire series instead of a single revision, accept (or reject) any revision in the series with '
        '"this series" in comment, which will be treated by Yadda specially. Batch accepting or rejecting is possible via command line like '
        code({}, "hg phabupdate --accept ':D#{revId}'")
        '.'
  else if stage == 'Needs 2nd Pass'
    nux = 'review-2p'
    help = div null,
      div className: 'mmb',
        '2nd Pass is mainly for reviewers with push access. Open revisions with at least one accept are listed here. '
        'They are expected to be either pushed, or rejected (so they go to "Needs Revision" stage).'
      div className: 'mmb',
        'Press ', kbd({}, 'c'), ' to copy revision IDs to clipboard. They are topo-sorted and can be used by ', code({}, 'hg phabread $CLIPBOARD'), '. '
        'When typing revisions manually, use', code({}, "hg phabread ':D#{revId}-closed'"), ' to get a series without closed (pushed) revisions.'
      div className: '',
        'To accept revisions in batch in a script, use something like', code({}, "hg phabupdate --accept ':D#{revId}' --comment 'Queued. Thanks!'"), '.'
  else if stage == 'Needs Revision'
    nux = 'review-revision'
    help = div null,
      div className: 'mmb',
        'Open revisions which has at least one reject on the latest version are shown here. What can happen next are:'
      ul style: {listStyle: 'inside disc', marginLeft: 8},
        li null, 'Reject is reasonable. Update the code and it returns to 1st Pass stage.'
        li null, 'Reject is unfair. Author could request review again. Or another reviewer can accept the change.'
        li null, 'Stay inactive for long. They will be eventually closed.'

  if !help || !nux || state.readNux[nux]
    return

  div className: 'phui-box phui-box-border phui-object-box mlb grouped',
    div className: 'phui-header-shell',
      h1 className: 'phui-header-view', stage
    div className: 'pm',
      help
    div className: 'pm',
      button className: 'button-green', onClick: (-> markNux state, nux), 'Got it!'

renderTable = (state, grevs, filteredRevs, getStatus) ->
  ago = moment().subtract(3, 'days') # display relative time within 3 days
  currRevs = _.keyBy(state.currRevs)
  # grevs could include revisions not in filteredRevs for series completeness
  filteredRevIds = _.keyBy(filteredRevs, (r) -> r.id)
  readMap = state.readMap # {id: dateModified}
  checked = state.checked
  columnCount = 7 # used by "colSpan" - count "th" below

  getSeriesRevIds = (id) ->
      ids = _.find(grevs, (revs) -> _.includes(revs.map((r) -> r.id), id)).map((r) -> r.id)

  handleCheckedClick = (id, e) ->
    if e.ctrlKey
      ids = getSeriesRevIds(id)
      markNux state, 'tick-series'
    else
      ids = [id]
      showNux state, 'tick-series', 'Hint: Hold "Ctrl" and click to toggle all checkboxes in a series'
    checked = state.checked
    ids.forEach (id) -> checked[id] = !checked[id]
    state.checked = checked
    e.target.blur()

  handleRowClick = (id, e, double = false) ->
    if double
      ids = getSeriesRevIds(id)
      markNux state, 'row-click'
    else
      ids = [id]
    if e.ctrlKey
      # invert
      selected = _.keyBy(state.currRevs, (id) -> id)
      ids.forEach (id) ->
        if selected[id]
          delete selected[id]
        else
          selected[id] = true
      state.currRevs = _.keys(selected)
      markNux state, 'row-click'
    else
      # select
      state.currRevs = ids
      showNux state, 'row-click', 'Hint: Hold "Ctrl" and click to focus multiple revisions. Double click to focus a series.'

  handleLinkClick = (e) ->
    if state.configArchiveOnOpen && _.includes([0, 1], e.button) # 0: left, 1: middle
      revId = /\/D([0-9]*)/.exec(e.currentTarget.href)[1]
      markAsRead state, null, [revId]

  describeStatus = (rev) ->
    status = getStatus(rev.id)
    join = (xs) -> _.join(xs, '')
    join ['accepts', 'rejects'].map (name) ->
      join status[name].map ([rId, x]) -> "#{describeAction(x)} at D#{rId}##{x.id}\n"

  table className: 'aphront-table-view',
    thead null,
      tr null,
        # selection indicator
        th style: {width: 4, padding: '8px 0px'}
        # profile
        th style: {width: 28, padding: '8px 0px'}, onClick: -> cycleSortKeys state, ['author'], title: 'Author'
        th onClick: (-> cycleSortKeys state, ['title', 'stack size']), 'Revision'
        if state.activeSortKey == 'phabricator status'
          columnCount += 1
          th className: 'phab-status', style: {width: 90}, onClick: (-> cycleSortKeys state, ['phabricator status']), 'Status'
        th className: 'actions', onClick: (-> cycleSortKeys state, ['activity count', 'phabricator status']), 'Activities'
        th className: 'size', style: {width: 50, textAlign: 'right'}, onClick: (-> cycleSortKeys state, ['line count', 'stack size']), 'Size'
        if state.activeSortKey == 'created'
          markNux state, 'sort-created'
          columnCount += 1
          th className: 'time created', style: {width: 90}, onClick: (-> cycleSortKeys state, ['created']), 'Created'
        th className: 'time updated', style: {width: 90}, onClick: (->
          showNux state, 'sort-created', 'Hint: Click at "Updated" the 3rd time to sort revisions by creation time'
          cycleSortKeys state, ['updated', 'created']), 'Updated'
        # checkbox
        th style: {width: 28, padding: '8px 0px'},
          renderActionSelector state, 'embedded'
    if grevs.length == 0
      tbody null,
        tr null,
          td colSpan: columnCount, style: {textAlign: 'center', padding: 10, color: '#92969D'},
            'No revision to show'
    grevs.map (subgrevs, i) ->
      lastAuthor = null # dedup same author
      tbody key: i,
        subgrevs.map (r) ->
          mtime = getDateModified(r)
          ctime = parseInt(r.dateCreated)
          lines = parseInt(r.lineCount)
          atime = getDateRead(state, readMap, r)
          actions = r.actions.filter((x) -> parseInt(x.dateModified) > ctime) # do not show actions creating a revision
          readActions = actions.filter((x) -> parseInt(x.dateModified) <= atime)
          unreadActions = actions.filter((x) -> parseInt(x.dateModified) > atime)

          # NUX prompts about certain cases
          if currRevs[r.id]
            if !filteredRevIds[r.id]
              showNux state, 'grey-rev', 'Hint: Some revisions are greyed out because they are filtered out, but another revision in a same patch series is not. Press <kbd>f</kbd> to remove them from focus. Press <kbd>s</kbd> to toggle display of those revisions.'
          tr key: r.id, className: "#{(atime >= mtime) && 'read' || 'not-read'} #{filteredRevIds[r.id] && 'active-appear' || 'passive-appear'} #{atime == _muteDate && 'muted'} #{checked[r.id] && 'selected'}", onClick: ((e) -> handleRowClick(r.id, e)), onDoubleClick: ((e) -> handleRowClick(r.id, e, true)),
            td className: "#{currRevs[r.id] && 'selected' || 'not-selected'} selector-indicator"
            td className: 'author',
              if r.author != lastAuthor
                lastAuthor = r.author
                renderProfile(state, r.author)
            td className: 'title', title: r.summary,
              strong onClick: handleCheckedClick.bind(this, r.id), title: describeStatus(r), "D#{r.id} "
              a href: "/D#{r.id}", onClick: handleLinkClick,
                strong null, r.title
            if state.activeSortKey == 'phabricator status'
              td className: "phab-status #{r.status.toLowerCase().replace(/ /g, '-')}", r.status
            td className: 'actions',
              renderActivities state, r, readActions, "read #{unreadActions.length > 0 && 'shrink' || ''}", handleLinkClick
              renderActivities state, r, unreadActions, 'unread', handleLinkClick
            td className: 'size',
              span className: 'size', "#{lines} line#{lines > 1 && 's' || ''}"
            (if state.activeSortKey == 'created' then [ctime, mtime] else [mtime]).map (time, i) ->
              time = moment.unix(time)
              td key: i, title: time.format('LLL'), className: 'time',
                if time > ago
                  time.fromNow()
                else
                  time.format('MMM D')
            td className: 'checkbox',
              input type: 'checkbox', checked: (checked[r.id] || false), onClick: ((e) -> handleCheckedClick(r.id, e))

renderLoadingIndicator = (state) ->
  if state.error
    div className: 'phui-info-view phui-info-severity-error',
      state.error
  else
    div style: {textAlign: 'center', marginTop: 240, color: '#92969D'},
      p null, 'Fetching data...'
      progress style: {height: 10, width: 100}

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
    if e.ctrlKey
      delete presets["#{i}"]
    else
      presets["#{i}"] = _.clone(state.activeFilter)
    state.presets = presets
  renderConfigItem 'Filter Presets', 'Once filters are saved to presets, they can be quickly activated by pressing corresponding number keys.',
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
        button {className, title, onClick: (e) -> handlePresentSave(i, e)}, i

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
  renderConfigItem 'Reset', 'Restore config options to default values and make hints appear again.',
    span className: 'config-value',
      button className: 'button-red small', onClick: handleReset, 'Reset'

renderSettings = (state) ->
  div style: {margin: 16},
    div className: 'config-list',
      renderBooleanConfig state, 'Series Display', 'configFullSeries', 'If D1 and D2 belong to a same series, and D1 is filtered out but not D2. This controls whether D1 is visible or not.', 'Show Entire Series', 'Show Only Individual Revisions'
      renderBooleanConfig state, 'Archive on Open', 'configArchiveOnOpen', 'Archive revisions being opened. Useful if you want to see a patch only once.', 'Enable Archive on Open', 'Disable Archive on Open'
      renderFilterPresets state
      renderCodeSourceSelector state
      renderConfigReset state

renderDialog = (state) ->
  name = state.dialog
  if !name
    return
  [
    div className: 'jx-mask', key: '1'
    div className: 'jx-client-dialog', style: {left: 0, top: 76}, key: '2',
      div className: 'aphront-dialog-view aphront-dialog-view-standalone',
        div className: 'aphront-dialog-head',
          div className: 'phui-header-shell',
            h1 className: 'phui-header-header', _.capitalize(name)
        if name == 'settings'
          renderSettings state
        div className: 'aphront-dialog-tail grouped',
          button onClick: (-> state.dialog = null), 'Looks good'
  ]

@render = (state) ->
  # Make it easier for debugging using F12 developer tools
  window.state = state

  if not state.revisions
    return renderLoadingIndicator(state)

  normalizeState state
  allRevs = state.revisions
  [getSeriesId, topoSort] = getTopoSorter(allRevs)
  getStatus = getStatusCalculator(state, getSeriesId)
  window.getStatus = getStatus
  revs = filterRevs(state, getStatus)
  grevs = groupRevs(state, revs, getSeriesId, topoSort)
  installKeyboardShortcuts state, grevs, revs, topoSort

  div className: 'yadda',
    style null, stylesheet
    div className: 'phui-navigation-shell phui-basic-nav',
      div className: 'phabricator-nav',
        div className: 'phabricator-nav-local phabricator-side-menu',
          renderFilterList state
        div className: 'phabricator-nav-content yadda-content',
          if state.error
            div className: 'phui-info-view phui-info-severity-error',
              state.error
          renderReviewNux state
          renderTable state, grevs, revs, getStatus
          span className: 'table-bottom-info',
            span onClick: (-> cycleSortKeys state, sortKeyFunctions.map((k) -> k[0])),
              "Sorted by: #{state.activeSortKey}, #{if state.activeSortDirection == 1 then 'ascending' else 'descending'}. "
            if state.updatedAt
              "Last update: #{state.updatedAt.calendar()}."
            ' '
            a onClick: (-> showDialog state, 'settings'), 'Settings'
      renderActionSelector state, 'mobile'
    renderDialog state

stylesheet = """
.yadda .aphront-table-view td { padding: 3px 4px; }
.yadda table { table-layout: fixed; }
.yadda thead { cursor: default; }
.yadda code, .yadda kbd { background: #EBECEE; padding: 0px 4px; margin: 0px 2px; border-radius: 3px; }
.yadda td input { display: inline-block; vertical-align: middle; margin: 3px 5px; }
.yadda td.selected, .yadda td.not-selected { padding: 0px 2px; }
.yadda td.selected { background: #3498db; }
.yadda td.size { text-align: right; }
.yadda tbody { border-bottom: 1px solid #D0E0ED; }
.yadda tbody:last-child { border-bottom: transparent; }
.yadda .profile { width: 20px; height: 20px; display: inline-block; vertical-align: middle; background-size: cover; background-position: center top; background-repeat: no-repeat; background-clip: content-box; border-radius: 2px; }
.yadda .profile.action { margin: 1px; float: left; }
.yadda .profile.action.read { opacity: 0.4; }
.yadda .profile.action.read.shrink { width: 11px; border-bottom-right-radius: 0; border-top-right-radius: 0; margin-left: 0; margin-right: 0; box-shadow: inset -1px 0px 0px 0px rgba(255,255,255,0.5); }
.yadda .profile.action.read.shrink:nth-child(n+2) { border-bottom-left-radius: 0; border-top-left-radius: 0; }
.yadda .profile.sensible-action { height: 15px; padding-bottom: 1px; border-bottom-right-radius: 0; border-bottom-left-radius: 0; border-bottom-width: 4px; border-bottom-style: solid; }
.yadda .profile.sensible-action.series { height: 13px; border-bottom-width: 6px; }
.yadda .profile.accept { border-bottom-color: #139543; }
.yadda .profile.reject { border-bottom-color: #C0392B; }
.yadda .profile.update { border-bottom-color: #3498DB; }
.yadda .profile.request-review { border-bottom: 4px solid #6e5cb6; }
.yadda td.title { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
/* .yadda tr.read { background: #f0f6fa; } */
/* .yadda tr.read td.title, .yadda tr.read td.time, .yadda tr.read td.size { opacity: 0.6; } */
.yadda tr.read.muted { background: #f8e9e8; }
.yadda tr.passive-appear, .yadda tr.passive-appear:hover { background-color: #EFF1F7; }
.yadda tr.passive-appear td.title, .yadda tr.passive-appear td.time, .yadda tr.passive-appear td.size { opacity: 0.6; }
.yadda tr.selected, .yadda tr.selected:hover { background-color: #FDF3DA; }
.yadda .table-bottom-info { margin-top: 12px; margin-left: 8px; display: block; color: #74777D; }
.yadda .phab-status.accepted { color: #139543 }
.yadda .phab-status.needs-revision { color: #c0392b }
.yadda .action-selector { border: 0; border-radius: 0; }
.yadda .action-selector:focus { outline: none; }
.yadda .yadda-content { margin-bottom: 16px }
.yadda .config-item { margin-bottom: 20px; }
.yadda .config-desc { margin-left: 160px; margin-bottom: 8px;}
.yadda .config-oneline-pair { display: flex; align-items: baseline; }
.yadda .config-name { width: 146px; font-weight: bold; color: #6B748C; text-align: right; margin-right: 16px; }
.yadda .action-selector.embedded { float: right; padding: 0; background-color: transparent; height: 100%; color: black; }
.yadda .action-selector.mobile {  position: fixed; bottom: 0; width: 100%; border-top: 1px solid #C7CCD9; z-index: 10; }
.got-it { margin-top: 8px; margin-right: 12px; display: block; float: right; }
.device-desktop .action-selector.mobile { display: none; }
.device-tablet .action-selector.mobile { display: none; }
.device-phone .action-selector.embed { display: none; }
.device-desktop .yadda-content { margin: 16px; }
.device-desktop th.actions { width: 30%; }
.device-tablet th.actions { width: 35%; }
.device-tablet th.size, .device-tablet td.size { display: none; }
.device-tablet .yadda table, .device-phone .yadda table { border-left: none; border-right: none; }
.device-phone thead, .device-phone td.time, .device-phone td.size { display: none; }
.device-phone td.selector-indicator { display: none; }
.device-phone td.author { display: none; }
.device-phone td.title { float: left; font-size: 1.2em; max-width: 100%; }
.device-phone td.phab-status { display: none; }
.device-phone td.actions { float: right; }
.device-phone td.checkbox { display: none; }
.device-phone .table-bottom-info { margin-bottom: 30px; }
.device-phone .yadda .config-oneline-pair { flex-wrap: wrap; }
.device-phone .yadda .config-desc { margin-left: 0; }
.device-phone .yadda .config-name { width: 100%; text-align: left; }
"""
