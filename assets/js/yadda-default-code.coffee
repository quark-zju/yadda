# This is a live CoffeeScript editor affecting the Yadda interface.
# Code will be saved to localStorage automatically if compiles.
#
# The entry point is "@render(state)" which returns ReactElement.
# "state" is refreshed periodically.
#
# LoDash, Moment.js, React.js and Javelin are available.

# Pre-defined queries
# Change this to affect the navigation side bar
queries = [
  ['Unread', (revs) ->
    readMap = getReadMap()
    revs.filter (r) -> parseInt(r.dateModified) > getDateRead(readMap, r)],
  ['Commented', (revs) -> revs.filter (r) -> r.actions.some((x) -> x.comment? && x.author == user)],
  ['Authored', (revs) -> revs.filter (r) -> r.author == user],
  ['All', (revs) -> revs],
]

# Use selected query and repo to filter revisions
filterRevs = (state) ->
  revs = state.revisions
  # filter by repo
  repo = state.activeRepo || 'All'
  if repo != 'All'
    revs = _.filter(revs, (r) -> r.callsign == repo)
  # filter by query
  entry = _.find(queries, (q) -> q[0] == state.activeQuery)
  if entry?
    func = entry[1]
    if func?
      revs = func(revs, state)
  revs

# Group by stack and sort them
groupRevs = (state, revs) -> # [rev] -> [[rev]]
  allRevs = state.revisions
  byId = _.keyBy(allRevs, (r) -> r.id)
  getDep = _.memoize((revId) ->
    _.min(byId[revId].dependsOn.map((i) -> getDep(i))) || revId)
  gmap = _.groupBy(revs, (r) -> getDep(r.id))
  # for series, sort by date
  groupSortKey = (revs) ->
    -_.max(revs.map((r) -> parseInt(r.dateModified)))
  # within a series, sort by id
  singleSortKey = (r) -> -parseInt(r.id)
  _.map(_.sortBy(_.values(gmap), groupSortKey), (revs) ->
    _.sortBy(revs, singleSortKey))

# Current user
user = null
try
  user = /\/([^/]*)\/$/.exec(document.querySelector('a.phabricator-core-user-menu').href)[1]

# Get repo callsigns, plus "All", sort them reasonably (shortest first)
getRepos = (state) ->
  repos = _.uniq(state.revisions.map((r) -> r.callsign || 'All'))
  repos = _.sortBy(repos, (r) -> [r == 'All', r.length, r])

# Mark as read - record dateModified
getReadMap = -> # {id: dateModified}
  result = {}
  try
    result = JSON.parse(localStorage['revRead'])
  result

markAsRead = (state, revIds) ->
  marked = getReadMap()
  revMap = _.keyBy(state.revisions, (r) -> r.id)
  # remove closed revisions
  marked = _.pickBy(marked, (d, id) -> revMap[id])
  # read dateModified
  revIds.forEach (id) ->
    if revMap[id]
      marked[id] = parseInt(revMap[id].dateModified)
  localStorage['revRead'] = JSON.stringify(marked)

# Get timestamp of last "marked read" or commented
getDateRead = (readMap, rev) ->
  commented = _.max(rev.actions.filter((x) -> x.author == user).map((x) -> parseInt(x.dateModified))) || -1
  marked = readMap[rev.id] || -1
  _.max([marked, commented])

# One-time normalize "state". Fill fields used by this script.
normalizeState = (state) ->
  if not state.activeQuery?
    state.activeQuery = localStorage['activeQuery'] || queries[0][0]
  if not state.activeRepo?
    state.activeRepo = localStorage['activeRepo'] || getRepos(state)[0]
  if not state.checked?
    state.checked = {}

# Make selected rows visible
scrollIntoView = ->
  isVisible = (e) ->
    top = e.getBoundingClientRect().top
    bottom = e.getBoundingClientRect().bottom
    top >= 0 && bottom <= window.innerHeight
  document.querySelectorAll('td.selected').forEach (e) ->
    if not isVisible(e)
      e.scrollIntoView()

# Keyboard shortcuts
installKeyboardShortcuts = (state, grevs) ->
  if !JX? || !JX.KeyboardShortcut?
    return
  if not state.keyNext?
    (state.keyNext = new JX.KeyboardShortcut(['j'], 'Select next stack')).register()
  if not state.keyPrev?
    (state.keyPrev = new JX.KeyboardShortcut(['k'], 'Select previous stack')).register()
  if not state.keyNextSingle?
    (state.keyNextSingle = new JX.KeyboardShortcut(['J'], 'Select next revision')).register()
  if not state.keyPrevSingle?
    (state.keyPrevSingle = new JX.KeyboardShortcut(['K'], 'Select previous revision')).register()
  if not state.keySelAll?
    (state.keySelAll = new JX.KeyboardShortcut(['*'], 'Select all in current view')).register()
  if not state.keyToggle?
    k = (new JX.KeyboardShortcut(['x'], 'Toggle checkboxes for selected revisions')).setHandler ->
      checked = not ((state.currRevs || []).some (r) -> state.checked[r])
      (state.currRevs || []).forEach (r) -> state.checked[r] = checked
      state.set()
    (state.keyToggle = k).register()
  if not state.keyOpen?
    k = (new JX.KeyboardShortcut(['o'], 'Open a revision in new tab')).setHandler ->
      r = _.min(state.currRevs)
      if r
        window.open("/D#{r}", '_blank')
    (state.keyOpen = k).register()
  if not state.keyMarkRead?
    k = (new JX.KeyboardShortcut(['a'], 'Mark selected revisions as read')).setHandler ->
      markAsRead state, _.keys(_.pickBy(state.checked))
      state.set 'checked', {}
    (state.keyMarkRead = k).register()
  toId = (r) -> r.id
  getRevIds = (singleSelection) ->
    if singleSelection
      _.flatten(_.values(grevs)).map((r) -> [r.id])
    else
      _.values(grevs).map((rs) -> rs.map(toId))
  getIndex = (revIds) ->
    currRevs = state.currRevs || []
    _.findIndex(revIds, (rs) -> _.intersection(rs, currRevs).length > 0) || 0
  [[true, state.keyNextSingle, state.keyPrevSingle], [false, state.keyNext, state.keyPrev]].forEach (x) ->
    [single, next, prev] = x
    next.setHandler ->
      revIds = getRevIds(single)
      i = getIndex(revIds)
      state.set 'currRevs', revIds[_.min([i + 1, revIds.length - 1])] || []
      setTimeout scrollIntoView, 100
    prev.setHandler ->
      revIds = getRevIds(single)
      i = getIndex(revIds)
      state.set 'currRevs', revIds[_.max([i - 1, 0])] || []
      setTimeout scrollIntoView, 100
  state.keySelAll.setHandler ->
    state.set 'currRevs', _.flatten(_.values(grevs)).map(toId)

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

# React elements
{a, button, div, input, li, span, strong, style, table, tbody, td, th, thead, tr, ul} = React.DOM

renderQueryList = (state) ->
  ul className: 'phui-list-view',
    li className: 'phui-list-item-view phui-list-item-type-label',
      span className: 'phui-list-item-name', 'Queries'
    queries.map (q, i) ->
      name = q[0]
      selected = (state.activeQuery == name)
      li key: name, className: "phui-list-item-view phui-list-item-type-link #{selected and 'phui-list-item-selected'}",
        a className: 'phui-list-item-href', href: '#', onClick: (-> state.set 'activeQuery', name; localStorage['activeQuery'] = name),
          span className: 'phui-list-item-name', name

renderRepoList = (state) ->
  repos = getRepos(state)
  ul className: 'phui-list-view',
    li className: 'phui-list-item-view phui-list-item-type-label',
      span className: 'phui-list-item-name', 'Repos'
    repos.map (name, i) ->
      selected = (state.activeRepo == name)
      li key: name, className: "phui-list-item-view phui-list-item-type-link #{selected and 'phui-list-item-selected'}",
        a className: 'phui-list-item-href', href: '#', onClick: (-> state.set 'activeRepo', name; localStorage['activeRepo'] = name),
          span className: 'phui-list-item-name', name

renderProfile = (state, username, opts = {}) ->
  profile = state.profileMap[username]
  a _.extend({className: "profile", title: profile.realName, href: "/p/#{username}", style: {backgroundImage: "url(#{profile.image})"}}, opts)

renderActivities = (state, rev, actions) ->
  author = className = title = actionId = ''
  elements = []
  append = ->
    # [author, className, title, actionId] = buf
    if author
      elements.push span key: actionId,
        renderProfile state, author, href: "/D#{rev.id}##{actionId}", title: title, className: "#{className} profile action"
    author = className = title = actionId = ''
  _.sortBy(actions, (x) -> parseInt(x.dateCreated)).forEach (x) ->
    if parseInt(x.dateCreated) <= parseInt(rev.dateCreated) # do not show actions creating a revision
      return
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
  append()
  elements

renderTable = (state, grevs) ->
  ago = moment().subtract(3, 'days') # display relative time within 3 days
  currRevs = _.keyBy(state.currRevs || [])
  readMap = getReadMap() # {id: dateModified}
  table className: 'aphront-table-view',
    thead null,
      tr null,
        th style: {width: 4, padding: '8px 0px'}, ''  # selection indicator
        th style: {width: 10}, '' # checkbox
        th null, 'Revision'
        th colSpan: 2, style: {textAlign: 'center'}, title: 'Read | Unread', 'Activities'
        th style: {width: 20, textAlign: 'right'}, 'Size'
        th style: {width: 20}, 'Updated'
    grevs.map (subgrevs, i) ->
      lastAuthor = null # dedup same author
      tbody key: i,
        subgrevs.map (r) ->
          mtime = moment.unix(parseInt(r.dateModified))
          lines = parseInt(r.lineCount)
          atime = getDateRead(readMap, r)
          actions = r.actions
          readActions = actions.filter((x) -> parseInt(x.dateModified) <= atime)
          unreadActions = actions.filter((x) -> parseInt(x.dateModified) > atime)
          tr key: r.id, className: "#{(atime >= parseInt(r.dateModified)) && 'read' || 'not-read'} #{state.checked[r.id] && 'selected'}",
            td className: "#{currRevs[r.id] && 'selected' || 'not-selected'}"
            td null,
              input type: 'checkbox', checked: (state.checked[r.id] || false), onChange: (e) ->
                state.checked[r.id] = !state.checked[r.id]
                state.set()
                e.target.blur()
              if r.author != lastAuthor
                lastAuthor = r.author
                renderProfile(state, r.author)
            td className: 'title', title: r.summary,
              strong null, "D#{r.id} "
              a href: "/D#{r.id}",
                strong null, r.title
            td className: 'read-actions',
              renderActivities state, r, readActions
            td className: 'unread-actions',
              renderActivities state, r, unreadActions
            td null,
              span className: 'size', style: {width: lines / 7.2}, title: "#{lines} lines"
            [mtime].map (time, i) ->
              td key: i, title: time.format('LLL'),
                if time > ago
                  time.fromNow()
                else
                  time.format('MMM D')

stylesheet = """
.yadda .aphront-table-view td { padding: 3px 4px; }
.yadda td input { display: inline-block; vertical-align: middle; margin: 3px 5px; }
.yadda td.selected, .yadda td.not-selected { padding: 0px 2px; }
.yadda td.selected { background: #3498db; }
.yadda tbody { border-bottom: 1px solid #dde8ef }
.yadda tbody:last-child { border-bottom: transparent; }
.yadda span.size { height: 10px; background: #3498db; display: inline-block; float: right }
.yadda .profile { width: 20px; height: 20px; display: inline-block; vertical-align: middle; background-size: cover; background-position: left-top; background-repeat: no-repeat; background-clip: content-box;}
.yadda .profile.action { margin-right: 2px; }
.yadda .profile.accept, .yadda .profile.reject, .yadda .profile.update { height: 15px; padding-bottom: 1px; }
.yadda .profile.accept { border-bottom: 4px solid #139543; }
.yadda .profile.reject { border-bottom: 4px solid #C0392B; }
.yadda .profile.update { border-bottom: 4px solid #3498DB; }
.yadda td.read-actions { text-align: right; opacity: 0.5; max-width: 200px; overflow: auto; border-right: 1px dashed #dde8ef; padding-right: 1px; }
.yadda tr.read { background: #E2EEF5; }
.yadda tr.selected { background-color: #FDF3DA; }
"""

@render = (state) ->
  normalizeState state
  revs = filterRevs(state, state.revisions)
  grevs = groupRevs(state, revs)
  installKeyboardShortcuts state, grevs
  # Uncomment below and use F12 tool to see "state" structure
  # window.s = state
  div className: 'yadda',
    style null, stylesheet
    div className: 'phui-navigation-shell phui-basic-nav',
      div className: 'phabricator-nav',
        div className: 'phabricator-nav-local phabricator-side-menu',
          renderQueryList state
          renderRepoList state
        div className: 'phabricator-nav-content mlt mll mlr mlb',
          renderTable state, grevs
