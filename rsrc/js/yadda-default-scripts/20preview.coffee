{a, div, pre, span} = React.DOM
{describeAction, getDateModified, getDateRead, getStatusCalculator, getTopoSorter, handleRevisionLinkClick} = this

_diffs = {} # pre-fetched patches, {diffID: content}

renderProfile = (profile) ->
  a key: profile.userName, className: "profile", title: profile.realName, href: "/p/#{profile.userName}", style: {backgroundImage: "url(#{profile.image})"}

renderStatusProfiles = (state, statusList) ->
  names = _.uniq(statusList.map ([revId, x]) -> x.author)
  names.map (n) ->
    renderProfile state.profileMap[n]

requestDiffPreview = (diffId) ->
  if diffId && _.isUndefined(_diffs[diffId])
    _diffs[diffId] = null # mark as fetching
    setTimeout redraw, 100
    request '/api/differential.getrawdiff', diffID: diffId, (r) ->
      _diffs[diffId] = r.result
      redraw()

handleDiffDoubleClick = (e) ->
  window.e = _.clone(e)
  debugger

@renderPreview = (state, revIds, autoDiffPreview) ->
  [getSeriesId, topoSort] = getTopoSorter(state.revisions)
  getStatus = getStatusCalculator(state, getSeriesId)
  sortedRevIds = topoSort(revIds)
  revById = _.keyBy state.revisions, (r) -> r.id  
  readMap = state.readMap

  renderRevision = (state, rev) ->
    # sort actions so they get a thread view
    # do this by having a sort key: [replyToRootId, replyDepth, Id]
    actionById = _.keyBy rev.actions, (r) -> r.id
    getSortKey = _.memoize (id) ->
      replyTo = actionById[id]?.replyTo
      if replyTo
        [rootId, depth, origId] = getSortKey(replyTo)
        [rootId, depth + 1, parseInt(id)]
      else
        [parseInt(id), 0, parseInt(id)]
  
    atime = getDateRead(state, readMap, rev)
    status = getStatus(rev.id)
    
    if state.autoDiffPreview || (revIds.length == 1 && rev.lineCount < 70)
      # fetch diff content automatically
      diffId = _.max(rev.actions.filter((x) -> x.type == 'update').map((x) -> parseInt(x.diffId)))
      requestDiffPreview diffId
  
    lastAuthorIdent = [null, null]
    lastDateCreated = null
    ver = 0
    renderAction = (state, action) ->
      {id, type, author, dateCreated} = action
      profile = state.profileMap[author]
      ident = getSortKey(id)[1]
      hideProfile = _.isEqual lastAuthorIdent, [author, ident]
      lastAuthorIdent = [author, ident]
      className = 'preview-action'
      diff = undefined
      if parseInt(action.dateCreated) > atime
        className += ' unread'
      else
        className += ' read'
      div key: id,
        div className: className, style: {paddingLeft: ident * 26 + 26},
          div className: 'preview-action-profile',
            if !hideProfile
              renderProfile profile
          div className: 'preview-action-body',
            if type == 'update'
              ver += 1
              diff = _diffs[action.diffId]
              span className: "preview-action-#{type}",
                'sent '
                a href: "/D#{rev.id}?id=#{action.diffId}", "V#{ver}"
                if _.isUndefined(diff)
                  a className: 'preview-diff-link', onClick: (-> requestDiffPreview action.diffId), 'Preview'
                else if diff == null
                  span className: 'preview-diff-fetching-tip', '(Fetching)'
                else
                  a className: 'preview-diff-link', onClick: (-> delete _diffs[action.diffId]; redraw()), 'Hide'
            else if type == 'reject'
              span className: "preview-action-#{type}", 'requested changes'
            else if type == 'accept'
              span className: "preview-action-#{type}", 'accepted'
            else if type == 'plan-changes'
              span className: "preview-action-#{type}", 'planned changes'
            else if type == 'request-review'
              span className: "preview-action-#{type}", 'requested review'
            else if type == 'comment' || type == 'inline'
              span className: "preview-action-comment", action.comment
            if type == 'inline' && action.path
              span className: "preview-action-source",
                "#{_.last(action.path.split('/'))}:#{action.line}"
            if lastDateCreated != dateCreated
              lastDateCreated = dateCreated
              time = moment.unix(dateCreated)
              span className: 'preview-action-date', title: time.format('LLL'),
                time.fromNow()
        if diff
          pre className: "preview-diff-content", onDoubleClick: ((e) -> handleDiffDoubleClick(e)), diff
  
    div className: 'preview-revision', key: rev.id,
      div className: 'preview-revision-header',
        span className: 'preview-revision-title',
          "D#{rev.id} "
          a href: "/D#{rev.id}", onClick: ((e) -> handleRevisionLinkClick(state, e)),
            rev.title
        if status.accepts.length > 0
          span className: 'preview-accept-list preview-profile-list',
            ' +1 by '
            renderStatusProfiles state, status.accepts
        if status.rejects.length > 0
          span className: 'preview-reject-list preview-profile-list',
            ' -1 by '
            renderStatusProfiles state, status.rejects
        if rev.summary.length > 0 && rev.summary != ' '
          div className: 'preview-revision-summary',
            rev.summary
      div className: 'preview-action-list',
        _.sortBy(rev.actions, (x) -> getSortKey x.id).map (x) ->
          renderAction state, x

  div null,
    sortedRevIds.map (id) -> renderRevision state, revById[id]
    div className: 'aphront-dialog-tail grouped',
      if !state.autoDiffPreview && revIds.length > 1
        span style: {lineHeight: '25px'}, 'Press P again to preview patch content'
      button className: 'button-grey', onClick: (-> state.dialog = null), 'Close'
