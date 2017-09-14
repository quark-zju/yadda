# Main dashboard page
{a, br, button, code, div, hr, h1, input, kbd, li, optgroup, option, p, progress, select, span, strong, style, table, tbody, td, th, thead, tr, ul} = React.DOM

{MUTE_DATE, cycleSortKeys, describeAction, getDateModified, getDateRead, getFilterGroups, getIsSeriesAction, getSelectedFilters, getStatusCalculator, getTopoSorter, groupRevs, handleRevisionLinkClick, installKeyboardShortcuts, markAsRead, markNux, renderDialog, sensibleActionType, showDialog, showNux, sortKeyFunctions, stylesheet} = this

@renderMainPage = (state) ->
  allRevs = state.revisions
  [getSeriesId, topoSort] = getTopoSorter(allRevs)
  getStatus = getStatusCalculator(state, getSeriesId)
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
          renderBottomBar state
      renderActionSelector state, 'mobile'
    renderDialog state

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

changeFilter = (state, title, name, multiple = false) ->
  active = state.activeFilter
  if _.isEqual(active[title], [name])
    active[title] = []
  else if not _.isArray(active[title]) or not multiple
    active[title] = [name]
    showNux state, 'multi-filter', 'Hint: Hold "Alt" and click to select (or remove) multiple filters.'
  else
    v = (active[title] ||= [])
    if _.includes(v, name)
      active[title] = _.without(v, name)
    else
      v.push(name)
    markNux state, 'multi-filter'
  state.activeFilter = active

# Render functions for sub-components
renderFilterList = (state) ->
  active = state.activeFilter
  handleFilterClick = (e, title, name) ->
    changeFilter state, title, name, e.ctrlKey || e.altKey
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
      changeFilter state, title, name, true
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
          option key: i, value: "F#{JSON.stringify([title, name])}", "#{name}#{selected[name] && ' (*)' || ''}"
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

  div className: 'phui-box phui-box-border phui-object-box mlb grouped', style: {borderRadius: 0}, # square-cornered to be consistent with the table
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
  columnCount = 8 # used by "colSpan" - count "th" below

  getSeriesRevIds = (id) ->
      ids = _.find(grevs, (revs) -> _.includes(revs.map((r) -> r.id), id)).map((r) -> r.id)

  handleCheckedClick = (id, e) ->
    if e.ctrlKey || e.altKey
      ids = getSeriesRevIds(id)
      markNux state, 'tick-series'
    else
      ids = [id]
      showNux state, 'tick-series', 'Hint: Hold "Alt" and click to toggle all checkboxes in a series'
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
    if e.ctrlKey || e.altKey
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
      showNux state, 'row-click', 'Hint: Hold "Alt" and click to focus multiple individual revisions. Double click to focus a series.'

  handleLinkClick = (e) ->
    handleRevisionLinkClick state, e

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
        th className: 'yadda-status', style: {width: 50}, 'Needs'
        th className: 'actions', onClick: (-> cycleSortKeys state, ['activity count']), 'Activities'
        th className: 'size', style: {width: 50, textAlign: 'right'}, onClick: (-> cycleSortKeys state, ['line count', 'stack size']), 'Size'
        if state.activeSortKey == 'created'
          markNux state, 'sort-created'
          columnCount += 1
          th className: 'time created', style: {width: 90}, onClick: (-> cycleSortKeys state, ['created']), 'Created'
        th className: 'time updated', style: {width: 90}, onClick: (->
          showNux state, 'sort-created', 'Hint: Click "Updated" the 3rd time to sort revisions by creation time'
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
          status = getStatus(r.id)
          statusClassName = ''
          if status.accepts.length > 0
            statusClassName += 'has-accepts'
          else if status.rejects.length > 0
            statusClassName += 'has-rejects'

          # NUX prompts about certain cases
          if currRevs[r.id]
            if !filteredRevIds[r.id]
              showNux state, 'grey-rev', 'Hint: Some revisions are greyed out because they are filtered out, but another revision in a same patch series is not. Press <kbd>f</kbd> to remove them from focus. Press <kbd>s</kbd> to toggle display of those revisions.'
          tr key: r.id, className: "#{(atime >= mtime) && 'read' || 'not-read'} #{filteredRevIds[r.id] && 'active-appear' || 'passive-appear'} #{atime == MUTE_DATE && 'muted'} #{checked[r.id] && 'selected'}", onClick: ((e) -> handleRowClick(r.id, e)), onDoubleClick: ((e) -> handleRowClick(r.id, e, true)),
            td className: "#{currRevs[r.id] && 'selected' || 'not-selected'} selector-indicator"
            td className: 'author',
              if r.author != lastAuthor
                lastAuthor = r.author
                renderProfile(state, r.author)
            td className: 'title', title: r.summary,
              strong onClick: handleCheckedClick.bind(this, r.id), title: describeStatus(r), "D#{r.id} "
              a href: "/D#{r.id}", onClick: handleLinkClick,
                strong null, r.title
            td className: "yadda-status",
              span className: "#{status.accepts.length > 0 && 'yadda-status-has-accepts' || ''} #{status.rejects.length > 0 && 'yadda-status-has-rejects' || ''}",
                if status.rejects.length > 0
                  'Revision'
                else if status.accepts.length > 0
                  '2nd Pass'
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
              input type: 'checkbox', readOnly: true, checked: (checked[r.id] || false), onClick: ((e) -> handleCheckedClick(r.id, e))

renderBottomBar = (state) ->
  span className: 'table-bottom-info',
    span onClick: (-> cycleSortKeys state, sortKeyFunctions.map((k) -> k[0])),
      "Sorted by: #{state.activeSortKey}, #{if state.activeSortDirection == 1 then 'ascending' else 'descending'}. "
    if state.updatedAt
      "Last update: #{state.updatedAt.calendar()}."
    ' '
    a onClick: (-> showDialog state, 'settings'), 'Settings'
