# This is a live CoffeeScript editor affecting the Yadda interface.
# Code change will be sent to the main Yadda page which saves it to localStorage
# (and also to Phabricator, see below).
#
# The entry point is "@render(state)" which returns ReactElement. The most
# interesting information is "state.revisions". See /conduit/method/yadda.query
# for what "state.revisions" look like. The "yadda.query" query will be called
# to update "state" periodically.
#
# If localStorage.sync is not set to "false", most states will be synchronized
# with Phabricator so it works across multiple machines.
#
# Javascript libraries LoDash, Moment.js, React.js and Javelin are available.

# Pre-defined filters
# Change this to affect the navigation side bar
getFilterGroups = (state) ->
  readMap = state.readMap

  # Filter actions - return actions since last code update
  afterUpdateActions = (r) ->
    mtime = getDateCodeUpdated(r)
    r.actions.filter((t) -> parseInt(t.dateModified) > mtime)

  # [name, filterFunc]
  reviewFilters = [
    ['Needs 1st Pass', (revs) -> revs.filter (r) -> r.author != state.user && r.status == 'Needs Review' && not afterUpdateActions(r).some((t) -> t.type == 'accept')]
    ['Needs 2nd Pass', (revs) -> revs.filter (r) -> r.author != state.user && (r.status == 'Accepted' || (r.status == 'Needs Review' && afterUpdateActions(r).some((t) -> t.type == 'accept')))]
    ['Needs Revision', (revs) -> revs.filter (r) -> r.author != state.user && r.status == 'Needs Revision']
  ]

  # logged-in user has more filters
  if state.user
    reviewFilters = reviewFilters.concat [
      ['Authored', (revs) -> revs.filter (r) -> r.author == state.user]
      ['Commented', (revs) -> revs.filter (r) -> r.actions.some((x) -> x.comment? && x.author == state.user)]
      ['Subscribed', (revs) -> revs.filter (r) -> r.ccs.includes(state.user)]
    ]

  updateFilters = [
    ['Has Any Updates', (revs) -> revs.filter (r) -> getDateModified(r) > getDateRead(state, readMap, r)]
    ['Has Code Updates', (revs) -> revs.filter (r) -> getDateCodeUpdated(r) > getDateRead(state, readMap, r)]
    ['Archived', (revs) -> revs.filter (r) -> t = getDateRead(state, readMap, r); getDateModified(r) <= t && t != _muteDate]
  ]

  repos = _.uniq(state.revisions.map((r) -> r.callsign || _noFilter))
  repos = _.sortBy(repos, (r) -> [r == _noFilter, r.length, r])
  repoFilters = repos.map (repo) -> [repo, ((revs) -> revs.filter (r) -> r.callsign == repo || repo == _noFilter)]

  # [(group title, [(name, filterFunc)])]
  [
    ['Reviews', reviewFilters]
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

_noFilter = 'All'

# Use selected query and repo to filter revisions
filterRevs = (state) ->
  revs = state.revisions
  active = state.activeFilter
  getFilterGroups(state).map ([title, filters]) ->
    selectedName = active[title] || filters[0][0]
    entry = _.find(filters, (f) -> f[0]  == selectedName)
    if entry
      func = entry[1]
      if func
        revs = func(revs, state)
  revs

# Group by series for selected revs and sort them
groupRevs = (state, revs) -> # [rev] -> [[rev]]
  allRevs = state.revisions
  byId = _.keyBy(allRevs, (r) -> r.id)
  getDep = _.memoize((revId) ->
    _.min(byId[revId].dependsOn.map((i) -> getDep(i))) || revId)
  # seriesId: [rev]
  sortRevsByDep = _.groupBy(revs, (r) -> getDep(r.id))
  # config: do we always include entire series even if only few revs are picked
  if state.config.noFullSeries # do not include full series
    showRevsByDep = sortRevsByDep
  else # include full series
    showRevsByDep =_.groupBy(allRevs, (r) -> getDep(r.id))
  # for series, use selected sort function
  entry = _.find(sortKeyFunctions, (q) -> q[0] == state.activeSortKey)
  groupSortKey = if entry then entry[1] else sortKeyFunctions[0][1]
  gsorted = _.sortBy(_.keys(sortRevsByDep), (d) -> groupSortKey(sortRevsByDep[d], state))
  if state.activeSortDirection == -1
    gsorted = _.reverse(gsorted)
  # within a series, sort by dependency topology
  getDepChain = _.memoize((revId) ->
    depends = byId[revId].dependsOn
    _.join(_.concat(depends.map(getDepChain), [_.padStart(revId, 8)])))
  gsorted.map (d) -> _.reverse(_.sortBy(showRevsByDep[d], (r) -> getDepChain(r.id)))

# Mark as read - record dateModified
markAsRead = (state, markDate = null) ->
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
  syncProperty = state.defineSyncedProperty
  syncRemotely = state.sync # if set, sync some state remotely
  if not state.activeFilter
    syncProperty 'activeFilter', {}, syncRemotely
  if not state.activeSortKey
    syncProperty 'activeSortKey', sortKeyFunctions[0][0], syncRemotely
  if not state.activeSortDirection
    syncProperty 'activeSortDirection', -1, syncRemotely
  if not state.currRevs
    syncProperty 'currRevs', [] # do not sync remotely
  if not state.readMap
    syncProperty 'readMap', {}, syncRemotely
  if not state.checked
    syncProperty 'checked', {} # do not sync remotely
  if not state.config
    syncProperty 'config', {}, syncRemotely

# Make selected rows visible
scrollIntoView = ->
  isVisible = (e) ->
    top = e.getBoundingClientRect().top
    bottom = e.getBoundingClientRect().bottom
    top >= 0 && bottom <= window.innerHeight
  document.querySelectorAll('td.selected').forEach (e) ->
    if not isVisible(e)
      e.scrollIntoView()

# Copy to clipboard
copyWithNotif = (text) ->
  if not text
    return
  copy(text)
  new JX.Notification().setContent("Copied: #{text}").setDuration(3000).show()

# Keyboard shortcuts
_lastIndex = -1
_muteDate = Number.MAX_SAFE_INTEGER
installKeyboardShortcuts = (state, grevs) ->
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
      index = _lastIndex # best-effort guess when things got deleted
    _lastIndex = index
  focusNext = (revIds) ->
      i = getIndex(revIds)
      state.currRevs = revIds[_.min([i + 1, revIds.length - 1])] || []
      setTimeout scrollIntoView, 100
  focusPrev = (revIds) ->
      i = getIndex(revIds)
      state.currRevs = revIds[_.max([i - 1, 0])] || []
      setTimeout scrollIntoView, 100

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

  shortcutKey ['o'], 'Open one of focused revisions in a new tab.', ->
    r = _.min(state.currRevs)
    if r
      window.open("/D#{r}", '_blank')
  shortcutKey ['O'], 'Open all of focused revisions in new tabs.', ->
    state.currRevs.forEach (r) -> window.open("/D#{r}", '_blank')

  shortcutKey ['a'], 'Archive selected revisions (mark as no new updates).', -> markAsRead state
  shortcutKey ['m'], 'Mute selected revisions (mark as no updates forever).', -> markAsRead state, _muteDate
  shortcutKey ['U'], 'Mark selected revisions as unread (if last activity is not by you).', -> markAsRead state, 0

  shortcutKey ['s'], 'Toggle always show full series.', -> c = state.config; c.noFullSeries = not c.noFullSeries; state.config = c

  copyIds = (ids) -> copyWithNotif _.join(ids.map((id) -> "D#{id}"), '+')

  shortcutKey ['c'], 'Copy focused revision numbers to clipboard.', -> copyIds(state.currRevs || [])
  shortcutKey ['C'], 'Copy selected revision numbers to clipboard.', -> copyIds(_.keys(_.pickBy(state.checked)))

  # Refresh only works for logged-in user. Since otherwise there is no valid CSRF token for Conduit API.
  if state.user
    shortcutKey ['r'], 'Fetch updates from server immediately.', refresh

# Transaction to human readable text
describeAction = (action) ->
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

# React elements
{a, button, div, input, li, optgroup, option, select, span, strong, style, table, tbody, td, th, thead, tr, ul} = React.DOM

renderFilterList = (state) ->
  active = state.activeFilter
  getFilterGroups(state).map ([title, filters]) ->
    if not _.some(filters, (f) -> f[0] == _noFilter)
      filters.push([_noFilter, (revs) -> revs])
    selectedName = active[title] || filters[0][0]

    ul className: 'phui-list-view', key: title,
      li className: 'phui-list-item-view phui-list-item-type-label',
        span className: 'phui-list-item-name', title
      filters.map ([name, func], i) ->
        selected = (selectedName == name)
        li key: name, className: "phui-list-item-view phui-list-item-type-link #{selected and 'phui-list-item-selected'}",
          a className: 'phui-list-item-href', href: '#', onClick: (-> t = state.activeFilter; t[title] = name; state.activeFilter = t),
            span className: 'phui-list-item-name', name

renderActionSelector = (state) ->
  active = state.activeFilter
  handleActionSelectorChange = (e) ->
    v = e.target.value
    if v[0] == 'F'
      [title, name] = JSON.parse(v[1..])
      t = state.activeFilter
      t[title] = name
      state.activeFilter = t
    else if v[0] == 'K'
      triggerShortcutKey v[1..]
    e.target.blur()
  checked = _.keys(_.pickBy(state.checked))
  select className: 'action-selector', onChange: handleActionSelectorChange, value: '+',
    option value: '+'
    if checked.length > 0
      optgroup label: "Action (#{checked.length} revision#{checked.length > 1 && 's' || ''})",
        option value: 'Ka', 'Archive'
        option value: 'Km', 'Mute'
        option value: 'KU', 'Mark Unread'
    getFilterGroups(state).map ([title, filters], j) ->
      selectedName = active[title] || filters[0][0]
      optgroup className: 'filter', label: title, key: j,
        filters.map ([name, func], i) ->
          selected = name == selectedName
          option key: i, disabled: selected, value: "F#{JSON.stringify([title, name])}", "#{name}#{selected && ' (*)' || ''}"
    option value: 'Ks', ' Toggle Full Series Display'
    option value: 'K~', 'Page Editor'

renderProfile = (state, username, opts = {}) ->
  profile = state.profileMap[username]
  a _.extend({className: "profile", title: profile.realName, href: "/p/#{username}", style: {backgroundImage: "url(#{profile.image})"}}, opts)

renderActivities = (state, rev, actions, extraClassName = '') ->
  author = className = title = actionId = ''
  elements = []
  append = ->
    # [author, className, title, actionId] = buf
    if author
      elements.push renderProfile state, author, href: "/D#{rev.id}##{actionId}", title: title, className: "#{extraClassName} #{className} profile action", key: actionId
    author = className = title = actionId = ''
  _.sortBy(actions, (x) -> parseInt(x.dateCreated)).forEach (x) ->
    if x.author != author
      append()
    author = x.author
    if ['accept', 'reject', 'update'].includes(x.type)
      className = x.type # the latest action wins
    desc = describeAction(x)
    if desc
      title += "#{desc}\n"
    if !actionId or parseInt(x.id) < actionId
      actionId = parseInt(x.id)
  className += ' last'
  append()
  elements

renderTable = (state, grevs, filteredRevs) ->
  ago = moment().subtract(3, 'days') # display relative time within 3 days
  currRevs = _.keyBy(state.currRevs)
  # grevs could include revisions not in filteredRevs for series completeness
  selectedRevIds = _.keyBy(filteredRevs, (r) -> r.id)
  readMap = state.readMap # {id: dateModified}
  checked = state.checked
  columnCount = 7 # used by "colSpan" - count "th" below

  handleCheckedChange = (id, e) ->
    checked = state.checked
    checked[id] = !checked[id]
    state.checked = checked
    e.target.blur()

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
          columnCount += 1
          th className: 'time created', style: {width: 90}, onClick: (-> cycleSortKeys state, ['created']), 'Created'
        th className: 'time updated', style: {width: 90}, onClick: (-> cycleSortKeys state, ['updated', 'created']), 'Updated'
        # checkbox
        th style: {width: 28, padding: '8px 0px'}
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

          tr key: r.id, className: "#{(atime >= mtime) && 'read' || 'not-read'} #{selectedRevIds[r.id] && 'active-appear' || 'passive-appear'} #{atime == _muteDate && 'muted'} #{checked[r.id] && 'selected'}", onClick: (-> state.currRevs = [r.id]),
            td className: "#{currRevs[r.id] && 'selected' || 'not-selected'} selector-indicator"
            td className: 'author',
              if r.author != lastAuthor
                lastAuthor = r.author
                renderProfile(state, r.author)
            td className: 'title', title: r.summary,
              strong onClick: handleCheckedChange.bind(this, r.id), "D#{r.id} "
              a href: "/D#{r.id}",
                strong null, r.title
            if state.activeSortKey == 'phabricator status'
              td className: "phab-status #{r.status.toLowerCase().replace(/ /g, '-')}", r.status
            td className: 'actions',
              renderActivities state, r, readActions, "read #{unreadActions.length > 0 && 'shrink' || ''}"
              renderActivities state, r, unreadActions, 'unread'
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
              input type: 'checkbox', checked: (checked[r.id] || false), onChange: handleCheckedChange.bind(this, r.id)

renderLoadingIndicator = (state) ->
  if state.error
    div className: 'phui-info-view phui-info-severity-error',
      state.error
  else
    div style: {textAlign: 'center', marginTop: 240, color: '#92969D'},
      React.DOM.p null, 'Fetching data...'
      React.DOM.progress style: {height: 10, width: 100}

@render = (state) ->
  # Make it easier for debugging using F12 developer tools
  window.state = state

  if not state.revisions
    return renderLoadingIndicator(state)

  normalizeState state
  revs = filterRevs(state, state.revisions)
  grevs = groupRevs(state, revs)
  installKeyboardShortcuts state, grevs

  div className: 'yadda',
    style null, stylesheet
    div className: 'phui-navigation-shell phui-basic-nav',
      div className: 'phabricator-nav',
        div className: 'phabricator-nav-local phabricator-side-menu',
          renderFilterList state
        div className: 'phabricator-nav-content yadda-content',
          renderActionSelector state
          if state.error
            div className: 'phui-info-view phui-info-severity-error',
              state.error
          renderTable state, grevs, revs
          span className: 'table-bottom-info',
            span onClick: (-> cycleSortKeys state, sortKeyFunctions.map((k) -> k[0])),
              "Sorted by: #{state.activeSortKey}, #{if state.activeSortDirection == 1 then 'ascending' else 'descending'}. "
            if state.updatedAt
              "Last update: #{state.updatedAt.calendar()}."

stylesheet = """
.yadda .aphront-table-view td { padding: 3px 4px; }
.yadda table { table-layout: fixed; }
.yadda thead { cursor: default; }
.yadda td input { display: inline-block; vertical-align: middle; margin: 3px 5px; }
.yadda td.selected, .yadda td.not-selected { padding: 0px 2px; }
.yadda td.selected { background: #3498db; }
.yadda td.size { text-align: right; }
.yadda tbody { border-bottom: 1px solid #dde8ef }
.yadda tbody:last-child { border-bottom: transparent; }
.yadda .profile { width: 20px; height: 20px; display: inline-block; vertical-align: middle; background-size: cover; background-position: center top; background-repeat: no-repeat; background-clip: content-box; border-radius: 2px; }
.yadda .profile.action { margin: 1px; float: left; }
.yadda .profile.action.read { opacity: 0.4; }
.yadda .profile.action.read.shrink { width: 11px; border-bottom-right-radius: 0; border-top-right-radius: 0; margin-left: 0; margin-right: 0; box-shadow: inset -1px 0px 0px 0px rgba(255,255,255,0.5); }
.yadda .profile.action.read.shrink:nth-child(n+2) { border-bottom-left-radius: 0; border-top-left-radius: 0; }
.yadda .profile.accept, .yadda .profile.reject, .yadda .profile.update { height: 15px; padding-bottom: 1px; border-bottom-right-radius: 0; border-bottom-left-radius: 0; }
.yadda .profile.accept { border-bottom: 4px solid #139543; }
.yadda .profile.reject { border-bottom: 4px solid #C0392B; }
.yadda .profile.update { border-bottom: 4px solid #3498DB; }
.yadda td.title { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.yadda tr.read { background: #f0f6fa; }
.yadda tr.read.muted { background: #f8e9e8; }
.yadda tr.read td.title, .yadda tr.read td.time, .yadda tr.read td.size { opacity: 0.5; }
.yadda tr.passive-appear { background-color: #F7F7F7; }
.yadda tr.passive-appear td.title, .yadda tr.passive-appear td.time, .yadda tr.passive-appear td.size { opacity: 0.5; }
.yadda tr.selected, .yadda tr.selected:hover { background-color: #FDF3DA; }
.yadda .table-bottom-info { margin-top: 12px; margin-left: 8px; display: block; color: #74777D; }
.yadda .phab-status.accepted { color: #139543 }
.yadda .phab-status.needs-revision { color: #c0392b }
.yadda .action-selector { border: 0; border-radius: 0; }
.yadda .action-selector:focus { outline: none; }
.yadda .yadda-content { margin-bottom: 16px }
.device-desktop .action-selector, .device-tablet .action-selector { float: right; padding: 0 16px; background-color: transparent; }
.device-desktop .action-selector { margin: 0 0 -34px; height: 34px; }
.device-desktop .action-selector optgroup.filter { display: none; }
.device-desktop .yadda-content { margin: 16px; }
.device-desktop th.actions { width: 30%; }
.device-tablet .action-selector { margin: 0 0 -30px; height: 30px; }
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
.device-phone .action-selector { position: fixed; bottom: 0; width: 100%; border-top: 1px solid #C7CCD9; z-index: 10; }
.device-phone .table-bottom-info { margin-bottom: 30px; }
"""

