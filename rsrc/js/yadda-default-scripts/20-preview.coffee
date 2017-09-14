{a, div, pre, progress, span, style, textarea} = React.DOM
{callConduit, describeAction, getDateModified, getDateRead, getStatusCalculator, getTopoSorter, handleRevisionLinkClick, requestAsync, scrollIntoView} = this

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
    onSuccess = (r) ->
      if r.result
        _diffs[diffId] = r.result
        redraw()
      else
        delete _diffs[diffId]
        # no redraw, avoid sending request too frequently
    onError = ->
      delete _diffs[diffId]
      # no redraw, avoid sending request too frequently
    request '/api/differential.getrawdiff', diffID: diffId, onSuccess, onError

getLastDiffId = (rev) ->
  _.max(rev.actions.filter((x) -> x.type == 'update').map((x) -> parseInt(x.diffId)))

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
      diffId = getLastDiffId(rev)
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
                else if revIds.length > 1 && !state.autoDiffPreview
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
          pre className: "preview-diff-content", diff
  
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

# reply shares some logic so it's in a same file
prefixLines = (text, prefix) ->
  text = text?.trim()
  if !text || text.length == 0
    ''
  else
    _.join(text.split('\n').map((t) -> "#{prefix}#{t}\n"), '')

class NotReadyError extends Error

calculateReplyTextForRevision = (state, rev) ->
  authorName = (x) -> state.profileMap[x.author]?.realName || x.author

  # check diff ID
  diffId = getLastDiffId(rev)
  if !_diffs[diffId]
    setTimeout (-> requestDiffPreview diffId), (parseInt(diffId) % 5) * 50
    throw new NotReadyError("Diff #{diffId} is not ready to comment")

  text = """
    > > [PATCH D#{rev.id}##{diffId}] #{rev.title}
    #{prefixLines(rev.summary.trim(), '> > ')}>\n
    """

  # append comments, analyse inlines
  inlines = {} # {path: {line: [action]}}
  _.sortBy(rev.actions, (x) -> parseInt(x.id)).forEach (x) ->
    if x.type == 'comment'
      text += """
        > #{authorName(x)} wrote at #{moment.unix(x.dateCreated).format('llll')}:
        #{prefixLines(x.comment, '>   ')}>\n
        """
    else if x.type == 'inline'
      inlines[x.path] ||= {}
      line = parseInt x.line
      if x.isNewFile == '0' # on the left
        line = -line
      (inlines[x.path][line] ||= []).push x

  # append patch body with inline comment
  appendInlines = (actions) ->
    if !actions || actions.length == 0
      return
    text += ">\n" + _.join((actions.map (x) ->
      verb = x.replyTo && 'replied' || 'wrote'
      """
      > #{authorName(x)} #{verb} at #{moment.unix(x.dateCreated).format('llll')} (INLINE #{x.id}):
      #{prefixLines(x.comment, '>   ')}
      """), ">\n") + ">\n"
  currentInline = {}
  currentLineLeft = currentLineRight = null
  for line in (_diffs[diffId] || '').trim().split("\n")
    if line[0...6] == '+++ b/'
      path = line[6..]
      currentInline = inlines[line[6..]] || {}
    else if line[0...3] == '@@ ' # ex.  @@ -155,8 +155,8 @@
      currentLineRight = parseInt line.split('+')[1].split(',')[0]
      currentLineLeft = parseInt line.split('-')[1].split(',')[0]

    text += "> > #{line}\n"

    if line[0] == ' ' || line[0] == '-'
      appendInlines currentInline[-currentLineLeft]
      currentLineLeft += 1
    if line[0] == ' ' || line[0] == '+'
      appendInlines currentInline[currentLineRight]
      currentLineRight += 1
  text + ">    \n\n"

discardable = (text) ->
  _.every text.trim().split('\n').map (t) -> t.length == 0 || t[0] == '>'

# see action.push for what actions are available
extractActions = (text) ->
  actions = [] # { revision, type (inline | comment | accept | ...), params } 
  curRevId = curDiffId = curCommentId = curLineRight = curPath = null

  rePatch = /^> > \[PATCH D([1-9]\d*)#(\d+)\]/ # [PATCH D1#4]
  rePatchAll = /^> > \[PATCH ALL\]/
  reComment = /^> [^>].*\(INLINE (\d+)\):/ # (INLINE ...)
  rePath = /^> > \+\+\+ b\/(.*)$/
  reLine = /^> > @@ -(\d+)[^ ]* \+(\d+)/
  reRightLine = /^> > [ +]/
  reAccept = /(\+1|\bLGTM|\blooks? good|\bqueued|!accept)\b/i
  reReject = /(\-1|!reject|\bneeds? change)\b/i
  reSeries = /\bth(e|is) series\b/i

  allRevIds = []
  text.split("\n").forEach (l) ->
    m = rePatch.exec l
    if m
      allRevIds.push m[1]

  buf = ''
  pushBuffer = ->
    buf = buf.trim()
    if buf.length == 0
      return
    revId = curRevId
    if revId
      # accept/reject
      type = null
      if reSeries.exec buf # special word affects everything
        revId = _.join(allRevIds, ',')
      if reReject.exec buf
        type = 'reject'
        buf = buf.replace(/!reject/g, '').trim()
      if reAccept.exec buf
        if type == 'reject'
          type = null
        else
          type = 'accept'
        buf = buf.replace(/!accept/g, '').trim()
      if type
        actions.push revision: revId, type: type, value: true
    if curRevId && !curPath || !curDiffId || !curLineRight
      # revision comment
      if buf.length > 0
        # comment should not be duplicated
        revId = if ',' in curRevId
                  _.last(allRevIds)
                else
                  curRevId
        actions.push revision: revId, type: 'comment', value: buf
    else
      # inline comment - sadly replyTo is missing from Phabricator APIs
      actions.push(
        revision: curRevId, diffID: curDiffId, type: 'inline', filePath: curPath,
        isNewFile: '1', lineNumber: _.max([curLineRight - 1, 1]), content: buf)
    buf = ''
    
  text.split("\n").forEach (l) ->
    if l[0] == '>'
      pushBuffer()
      m = rePatch.exec l
      if m
        curCommentId = curLineRight = curPath = null
        curRevId = m[1]
        curDiffId = m[2]
        return
      m = rePatchAll.exec l
      if m
        curCommentId = curLineRight = curPath = null
        curRevId = _.join(allRevIds, ',')
        return
      m = reComment.exec l
      if m
        curCommentId = m[1]
        return
      m = rePath.exec l
      if m
        curPath = m[1]
        return
      m = reLine.exec l
      if m
        curCommentId = null
        curLineRight = parseInt m[2]
        return
      if reRightLine.exec(l) && curLineRight != null
        curCommentId = null
        curLineRight += 1
        return
      if _.startsWith l, '>    '
        curLineRight = curPath = null
    else # user content
      buf += l + "\n"

  pushBuffer()
  actions

handleSubmit = (state, actions) ->
  state.dialog = null

  # convert actions to Conduit API calls
  inlineCalls = [] # [param], differential.createinline, call first
  inlineRevIds = []
  revisionCalls = {} # {revId: param}, differential.revision.edit

  # handle inline and batch actions first
  actions.forEach (x) ->
    if x.type == 'inline'
      {diffID, filePath, isNewFile, lineNumber, content} = x
      inlineCalls.push {diffID, filePath, isNewFile, lineNumber, content}
      inlineRevIds.push x.revision
    else if ',' in x.revision
      for revId in x.revision.split(',')
        (revisionCalls[revId] ||= []).push _.pickBy(x, (v, n) -> n == 'type' || n == 'value')

  # handle individual actions next (so they override batch actions)
  actions.forEach (x) ->
    if x.type != 'inline' && ',' not in x.revision
      revId = x.revision
      (revisionCalls[revId] ||= []).push _.pickBy(x, (v, n) -> n == 'type' || n == 'value')

  # call Conduit APIs
  try
    res = []
    for data in inlineCalls
      res.push await callConduit 'differential.createinline', data
    await Promise.all res

    # This is ugly. Unfortunately there is no Conduit API to make draft
    # comments visible. So send a POST request to Differential page.
    res = _.uniq(inlineRevIds).map (revId) ->
      url = "/differential/revision/edit/#{revId}/comment/"
      await requestAsync url, {comment: '', __form__: 1}, true, true
    await Promise.all res

    res = []
    for revId in _.sortBy(_.keys(revisionCalls))
      data = {objectIdentifier: "D#{revId}", transactions: revisionCalls[revId]}
      res.push await callConduit 'differential.revision.edit', data
    await Promise.all res

    state.replyDraft = ''
    notify "Reply sent."
    refresh()
  catch ex
    notify "Failed to send reply: #{ex}", 6000

renderDraftActions = (actions) ->
  div className: 'reply-draft-actions',
    span className: 'reply-draft-action', "'Submit' will do: "
    actions.map (x, i) ->
      revDesc = "D#{x.revision}"
      desc = if x.type == 'accept'
               "Accept #{revDesc}"
             else if x.type == 'reject'
               "Request changes of #{revDesc}"
             else if x.type == 'comment'
               "Comment on #{revDesc}: #{_.truncate(x.value.replace(/\n/g, ' '))}"
             else if x.type == 'inline'
               "Comment inline at #{revDesc} #{_.last(x.filePath.split('/'))}:#{x.lineNumber}: #{_.truncate(x.content.replace(/\n/g, ' '))}"
      span className: "reply-draft-action reply-draft-action-#{x.type}", key: i,
        desc

@renderReply = (state, revIds) ->
  text = state.replyDraft
  actions = extractActions text
  isEmpty = (actions.length == 0)
  if isEmpty
    [getSeriesId, topoSort] = getTopoSorter(state.revisions)
    failed = 0
    revById = _.keyBy state.revisions, (r) -> r.id  
    text = ''
    for revId in topoSort(revIds)
      rev = revById[revId]
      try
        text += calculateReplyTextForRevision(state, rev)
      catch ex
        if ex instanceof NotReadyError
          failed += 1
        else
          throw ex
    if failed > 0
      return div style: {display: 'flex', flexDirection: 'column', justifyContent: 'center', alignItems: 'center', height: 200},
        div null, 'Reading patches...'
        progress style: {height: 10, width: 100, marginTop: 20}, value: (revIds.length - failed), max: revIds.length
    else
      text += """
        > > [PATCH ALL] Comment below to reply to all patches above
        > > Special words: accept: "+1", "LGTM", "queued", "!accept";
        > >                request change: "-1", "!reject";
        >
        """

  handleKeyDown = (e) ->
    if e.ctrlKey && e.key == 'Enter'
      handleSubmit state, actions
      e.preventDefault()
    else
      scrollIntoView('.jx-client-dialog')

  div null,
    style null, 'html, body { overflow: hidden; }'
    textarea className: 'reply-editor', defaultValue: text, onKeyDown: handleKeyDown, onChange: (e) ->
      state.replyDraft = e.target.value
    div className: 'aphront-dialog-tail grouped',
      if !isEmpty
        span null,
          renderDraftActions actions
          button className: "button-grey", onClick: (-> state.dialog = null), 'Save Draft'
          button onClick: (-> handleSubmit state, actions), 'Submit'
          button className: "button-red", onClick: (-> state.replyDraft = ''; state.dialog = null), 'Discard'
      else
          button className: "button-grey", onClick: (-> state.dialog = null), 'Close'
