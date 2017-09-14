# Miscellaneous helper functions shared in Yadda UI
#
# If you are trying to customize the UI, maybe "filters", "keys", "style" tabs
# are more interesting.

# Show NUX notification
_shownNux = {}
@markNux = markNux = (state, type) ->
  readNux = state.readNux || {}
  if not readNux[type]
    readNux[type] = true
    state.readNux = readNux
@showNux = showNux = (state, type, html, duration = null) ->
  if state.readNux[type] || _shownNux[type]
    return
  duration ||= (html.length * 50) + 5000
  node = JX.$H("<div>#{html}<br/><a class=\"got-it\">Got it</a></div>").getNode()
  gotIt = node.querySelector('a.got-it')
  gotIt.onclick = -> markNux state, type
  _shownNux[type] = true
  notify node, duration

# Make selected elements visible
@scrollIntoView = scrollIntoView = (selector) ->
  isVisible = (e) ->
    top = e.getBoundingClientRect().top
    bottom = e.getBoundingClientRect().bottom
    top >= 0 && bottom <= window.innerHeight
  setTimeout((-> document.querySelectorAll(selector).forEach (e) ->
    if not isVisible(e)
      e.scrollIntoView()), 100)

# Generate utilities for topology sorting. Return 2 functions:
# - getSeriesId: revId -> seriesId
# - topoSort: revs -> sortedRevs
@getTopoSorter = (allRevs) ->
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
@getIsSeriesAction = getIsSeriesAction = (actions) ->
  seriesDates = {} # {dateCreated: true}
  actions.forEach (x) ->
    if x.comment && _seriesRe.exec(x.comment)
      seriesDates[x.dateCreated] = true
  (action) -> seriesDates[action.dateCreated] || false

# Normalize action type (ex. 'plan-changes' -> 'reject') and only return those
# we care about: accept, update, request-review, reject.
@sensibleActionType = sensibleActionType = (action) ->
  if action.type == 'plan-changes'
    'reject'
  else if _.includes(['accept', 'update', 'request-review', 'reject'], action.type)
    action.type

# Return a function:
# - getStatus: (revId) -> {accepts: [(revId, action)], rejects: [(revId, action)]}
# Update state.readMap according to series commented status
# Re-calculate revision statuses using 'actions' data.
# - Set '_status: {accept: [username], reject: [username]}'
#   - accept is sticky
#   - reject is not sticky
#   - accept and reject override each other.
#   - 'request-review'
#   - 'plan-changes' is seen as 'rejected'
#   - SPECIAL: comment with "this series" applies to every patches in the
#     series
# - Do not take Phabricator review status into consideration. This bypasses
#   blocking reviewers, non-sticky setting and unknown statuses.
@getStatusCalculator = (state, getSeriesId) ->
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
    _.sortBy(actions, ([verb, x, rId]) -> parseInt(x.id)).forEach ([verb, x, rId]) ->
      if verb == 'request-review'
        accepts = []
        rejects = []
      else if verb == 'update'
        rejects = []
      else if verb == 'accept'
        rejects = []
        accepts.push([rId, x])
      else if verb == 'reject'
        accepts = []
        rejects.push([rId, x])
    {accepts: accepts, rejects: rejects}

# Group by series for selected revs and sort them
@groupRevs = (state, revs, getSeriesId, topoSort) -> # [rev] -> [[rev]]
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
@MUTE_DATE = Number.MAX_SAFE_INTEGER
@markAsRead = markAsRead = (state, markDate = null, revIds = null) ->
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
@getDateRead = getDateRead = (state, readMap, rev) ->
  commented = _.max(rev.actions.filter((x) -> x.author == state.user).map((x) -> parseInt(x.dateModified))) || -1
  marked = readMap[rev.id] || -1
  _.max([marked, commented])

# Get timestamp of the last action of given revision
@getDateModified = getDateModified = (rev) ->
  # cannot use rev.dateModified since diff property update will bump that without generation a transaction/action
  _.max(rev.actions.map((x) -> parseInt(x.dateModified))) || -1

# Get timestamp of the last code update action
@getDateCodeUpdated = (rev) ->
  _.max(rev.actions.map((t) -> t.type == 'update' && parseInt(t.dateModified) || -1)) || -1

# async version of calling Conduit API
@requestAsync = requestAsync = (path, data, expectCSRF = false) ->
  p = new Promise (resolve, reject) ->
    request path, data, ((r) -> 
      if expectCSRF
        if r.error
          reject r.error
        else
          resolve r.payload
      else
        if r.result
          resolve r.result
        else
          reject r.error_info
    ), ((e) -> reject e), expectCSRF
  await p

@callConduit = (api, data) ->
  pairs = {}
  for k, v of data
    # use params[name] so value could be json encoded
    pairs["params[#{k}]"] = JSON.stringify(v)
  await requestAsync "/api/#{api}", pairs

# Open revisions in new tabs. Handles markAsRead.
@openRevisions = (state, revIds) ->
  if state.configArchiveOnOpen
    markAsRead state, null, revIds
  revIds.forEach (r) -> window.open("/D#{r}", '_blank')

@handleRevisionLinkClick = (state, e) ->
 if state.configArchiveOnOpen && _.includes([0, 1], e.button) # 0: left, 1: middle
   revId = /\/D([0-9]*)/.exec(e.currentTarget.href)[1]
   markAsRead state, null, [revId]

# Transaction to human readable text
@describeAction = (action) ->
  # See "ACTIONKEY" under phabricator/src/applications/differential/xaction
  verb = {
    'inline': 'commented inline'
    'comment': 'commented'
    'update': 'updated the code'
    'accept': 'accepted'
    'reject': 'requested changes'
    'close': 'closed the revision'
    'resign': 'resigned as reviewer'
    'abandon': 'abandoned the revision'
    'reclaim': 'reclaimed the revision'
    'reopen': 'reopened the revision'
    'plan-changes': 'planned changes'
    'request-review': 'requested review'
    'commandeer': 'commandeered the revision'
  }[action.type]
  if action.path and action.line
    verb += " at #{action.path}:#{action.line}"
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
@cycleSortKeys = (state, sortKeys) ->
  i = _.indexOf(sortKeys, state.activeSortKey)
  if i == -1 || state.activeSortDirection != -1
    state.activeSortKey = sortKeys[(i + 1) % sortKeys.length]
    state.activeSortDirection = -1
  else
    state.activeSortDirection = 1

@getSelectedFilters = (activeFilter, title, filters) ->
  result = {}
  if _.isArray(activeFilter[title])
    activeFilter[title].forEach (f) -> result[f] = true
  else
    # pick the first one as default
    if filters.length > 0
      result[filters[0][0]] = true
  result

@showDialog = (state, name, args...) ->
  if state.dialog == name
    state.dialog = null
  else
    state.dialog = name
    scrollIntoView('.jx-client-dialog')

# function to sort columns
@sortKeyFunctions = sortKeyFunctions = [
  ['updated', (revs, state) -> _.max(revs.map (r) -> getDateModified(r))]
  ['created', (revs, state) -> _.min(revs.map (r) -> parseInt(r.dateCreated))]
  ['author', (revs, state) -> _.min(revs.map (r) -> [r.author, parseInt(r.id)])]
  ['title', (revs, state) -> _.min(revs.map (r) -> r.title)]
  ['stack size', (revs, state) -> revs.length]
  ['activity count', (revs, state) -> _.sum(revs.map (r) -> r.actions.filter((x) -> parseInt(x.dateCreated) > parseInt(r.dateCreated)).length)]
  ['line count', (revs, state) -> _.sum(revs.map (r) -> parseInt(r.lineCount))]
]
