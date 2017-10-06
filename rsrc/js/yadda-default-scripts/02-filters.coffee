{MUTE_DATE, getDateCodeUpdated, getDateModified, getDateRead, getGetDepIds} = this

@getFilterGroups = (state, getStatus) =>
  readMap = state.readMap
  getDepIds = getGetDepIds state

  # A filter group has a list of (name, filterFunc) tuples.
  reviewFilters = [
    # Note: if "getStatus" is not passed, filter functions are incorrect, but titles are okay.
    ['Needs 1st Pass', (revs) -> revs.filter (r) -> getStatus(r.id).accepts.length == 0 && getStatus(r.id).rejects.length == 0]
    ['Needs 2nd Pass', (revs) -> revs.filter (r) -> getStatus(r.id).accepts.length > 0 && getDepIds(r.id).every((x) -> getStatus(x).rejects.length == 0)]
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
    ['Already Read', (revs) -> revs.filter (r) -> t = getDateRead(state, readMap, r); getDateModified(r) <= t && t != MUTE_DATE]
  ]

  repos = _.uniq(state.revisions.map((r) -> r.callsign || 'Unnamed'))
  repos = _.sortBy(repos, (r) -> [r == 'Unnamed', r.length, r])
  repoFilters = repos.map (repo) -> [repo, (revs) -> revs.filter (r) -> r.callsign == repo || (!r.callsign && repo == 'Unnamed')]

  # [(groupTitle, [(name, filterFunc)])]
  [
    ['Review Stages', reviewFilters]
    ['People', peopleFilters]
    ['Read States', updateFilters]
    ['Repositories', repoFilters]
  ]
