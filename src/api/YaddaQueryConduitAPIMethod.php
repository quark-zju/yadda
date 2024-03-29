<?php

final class YaddaQueryConduitAPIMethod extends ConduitAPIMethod {

  public function getAPIMethodName() {
    return 'yadda.query';
  }

  public function shouldRequireAuthentication() {
    return true;
  }

  public function getMethodDescription() {
    return pht('Get data useful for Yadda, including Differential Revision '.
      ' metadata, involved profiles and current user name. ');
  }

  public function getMethodDocumentation() {
    $text = pht(<<<EOT
**Input**

- `revisionIDs`: a list of Differential Revision IDs.
  If not set, return all open revisions.

**Output**

The output includes `revisions`, `profiles`, `user` and `state`. `revisions`
contains user interactions (ex. comment, accept, reject, update). `profiles`
contains metadata about users referred by `revisions`. `user` is the name of
current user issuing the API request. `state` is a string or `null` set by
`yadda.setstate` associated to the current user.

```lang=json
{ "revisions":
    [ { "id": "1", "callsign": "E", "title": "first commit",
        "author": "bob", "status": "Accepted",
        "summary": "The first comment.", "testPlan": "", "lineCount": "4",
        "dependsOn": [], "reviewers": [ "alice" ], "ccs": [ "alice" ],
        "actions":
          [ { "id": "10", "type": "accept", "author": "alice",
              "dateCreated": "1501528752", "dateModified": "1501528752" },
            { "id": "2", "type": "update", "author": "bob",
              "dateCreated": "1499014795", "dateModified": "1499014795" } ],
        "dateCreated": "1499014795", "dateModified": "1501528752" },
      { "id": "2", "callsign": "E", "title": "second commit",
        "author": "bob", "status": "Needs Review",
        "summary": "This depends on D1", "testPlan": "", "lineCount": "192",
        "dependsOn": ["1"], "reviewers": [], "ccs": ["alice"],
        "actions":
          [ { "id": "42", "type": "update", "author": "bob",
              "dateCreated": "1499026947", "dateModified": "1499026947" },
            { "id": "29", "type": "comment", "author": "alice",
              "comment": "Generally looks good to me.",
              "dateCreated": "1499017179", "dateModified": "1499017179" },
            { "id": "28", "type": "inline", "author": "alice",
              "comment": "nit: prefer `changeset` to `commit`",
              "dateCreated": "1499017179", "dateModified": "1499017179" } ],
        "dateCreated": "1499015153", "dateModified": "1499017179" } ],
  "profiles":
    [ { "userName": "alice", "realName": "Alice",
        "image": "http://phabricator.example.com/file/data/..." },
      { "userName": "bob", "realName": "Bob",
        "image": "http://phabricator.example.com/file/data/..." } ],
  "user": "alice",
  "state": null }
```

The `id` used in `revisions` are Differential Revision IDs that can be used
directly to construct `/Dn` URLs. `id` used in `actions` are internal IDs.

`dependsOn` will not have references to Differential Revisions that are not
requested.
EOT
);
    $engine = PhabricatorMarkupEngine::getEngine();
    $engine->setConfig('viewer', $this->getViewer());
    $engine->setConfig('preserve-linebreaks', false);
    $rendered = $engine->markupText($text);
    $div = phutil_tag_div('phabricator-remarkup mlb', $rendered);

    return id(new PHUIObjectBoxView())->appendChild($div);
  }

  protected function defineParamTypes() {
    return array(
      'revisionIDs' => 'optional list<int>',
    );
  }

  protected function defineReturnType() {
    return 'dict';
  }

  protected function execute(ConduitAPIRequest $request) {
    $viewer = $request->getUser();
    $ids = $request->getValue('revisionIDs', array());
    return self::query($viewer, $ids);
  }

  static public function query(
    PhabricatorUser $viewer,
    array $revision_ids) {
    $query = id(new DifferentialRevisionQuery())
      ->setViewer($viewer)
      ->needReviewers(true);
    if ($revision_ids) {
      $query->withIDs($revision_ids);
    } else {
      // See https://secure.phabricator.com/D18396
      if (method_exists($query, 'withIsOpen')) {
        $query->withIsOpen(true);
      } else {
        $query->withStatus(DifferentialRevisionQuery::STATUS_OPEN);
      }
    }
    $revisions = $query->execute();

    // Collecting profile images, key: username, value: URL
    $profile_map = array();

    // Details of revisions
    $xactions_map = self::loadTransactions($viewer, $revisions, $profile_map);
    $depends_on_map = self::loadDependsOn($viewer, $revisions);
    $ccs_map = array();
    $repos = array();
    if ($revisions) { 
      $ccs_map = id(new PhabricatorSubscribersQuery())
        ->withObjectPHIDs(mpull($revisions, 'getPHID'))
        ->execute();
      $repos = id(new PhabricatorRepositoryQuery())
        ->setViewer($viewer)
        ->withPHIDs(mpull($revisions, 'getRepositoryPHID'))
        ->execute();
    }
    $phid_callsign_map = mpull($repos, 'getCallsign', 'getPHID');

    // Collect all author PHIDs and prepare to convert them to names
    $phids = array_merge(
      mpull($revisions, 'getAuthorPHID'),
      array_mergev(mpull($revisions, 'getReviewerPHIDs')),
      array_mergev(array_values($ccs_map)));
    $phid_author_map = self::loadAuthorNameMap($viewer, $phids, $profile_map);
    
    // Compound result for each revision
    $revision_descs = array();
    foreach ($revisions as $revision) {
      $id = $revision->getID();
      $phid = $revision->getPHID();
      $desc = array(
        'id'           => $id,
        'callsign'     => idx(
          $phid_callsign_map, $revision->getRepositoryPHID()),
        'title'        => $revision->getTitle(),
        'author'       => $phid_author_map[$revision->getAuthorPHID()],
        'summary'      => $revision->getSummary(),
        'testPlan'     => $revision->getTestPlan(),
        'lineCount'    => $revision->getLineCount(),
        'dependsOn'    => $depends_on_map[$id],
        'reviewers'    => self::mapPHIDstoNames(
          $phid_author_map, $revision->getReviewerPHIDs()),
        'ccs'          => self::mapPHIDstoNames(
          $phid_author_map, idx($ccs_map, $phid, array())),
        'actions'      => $xactions_map[$id],
        'dateCreated'  => $revision->getDateCreated(),
        'dateModified' => $revision->getDateModified(),
      );
      if (method_exists($revision, 'getStatusDisplayName')) {
        $desc['status'] = $revision->getStatusDisplayName();
      } else {
        $desc['status'] = 
          ArcanistDifferentialRevisionStatus::getNameForRevisionStatus(
            $revision->getStatus());
      }
      $revision_descs[] = $desc;
    }

    $profile_descs = array();
    foreach ($profile_map as $name => $profile) {
      $profile_descs[] = array(
        'userName' => $name,
        'realName' => $profile->getRealName(),
        'image' => $profile->getProfileImageURI(),
      );
    }

    $result = array(
      'revisions' => $revision_descs,
      'profiles' => $profile_descs,
    );

    if ($viewer->getUserName()) {
      $result['user'] = $viewer->getUserName();
      $result['state'] = YaddaUserState::get($viewer);
    }

    return $result;
  }

  static protected function loadTransactions(
    PhabricatorUser $viewer,
    array $revisions,
    array &$profile_map) { // return {$revision_id => [$action]}
    if (!$revisions) {
      return array();
    }

    assert_instances_of($revisions, 'DifferentialRevision');

    $phid_revision_map = mpull($revisions, null, 'getPHID');

    $xactions = id(new DifferentialTransactionQuery())
      ->setViewer($viewer)
      ->withObjectPHIDs(mpull($revisions, 'getPHID'))
      ->needComments(true)
      ->execute();

    $phids = mpull($xactions, 'getAuthorPHID');
    $phid_author_map = self::loadAuthorNameMap($viewer, $phids, $profile_map);

    $changesets = self::loadInlineChangesets($viewer, $xactions);
    
    // Build commentPHID to xactionID map for resolving ReplyToCommentPHID
    $comment_phid_to_xaction_id = array();
    foreach ($xactions as $xaction) {
      if ($xaction->hasComment()) {
        $comment = $xaction->getComment();
        $comment_phid_to_xaction_id[$comment->getPHID()] = $xaction->getID();
      }
    }

    // Build diffPHID to diffID map for update actions
    $diff_phids = array();
    foreach ($xactions as $xaction) {
      $type = $xaction->getTransactionType();
      if ($type == DifferentialTransaction::TYPE_UPDATE) {
        $diff_phid = $xaction->getNewValue();
        if ($diff_phid) {
          $diff_phids[] = $diff_phid;
        }
      }
    }
    $diffs = id(new DifferentialDiffQuery())
      ->setViewer($viewer)
      ->withPHIDs($diff_phids)
      ->execute();
    $diff_phid_to_id = mpull($diffs, 'getID', 'getPHID');

    // Action keys could be: accept, reject, close, resign, abandon, reclaim,
    // reopen, accept, request-review, commandeer, plan-changes
    $actions = DifferentialRevisionActionTransaction::loadAllActions();
    $type_action_map = array();
    foreach ($actions as $key => $action) {
      $type_action_map[$action::TRANSACTIONTYPE] = $key;
    }

    // Transaction results for each revision
    $results = array();
    foreach ($xactions as $xaction) {
      $revision = idx($phid_revision_map, $xaction->getObjectPHID());
      if (!$revision) {
        continue;
      }

      $type = $xaction->getTransactionType();
      $value = array();

      if ($type == DifferentialTransaction::TYPE_INLINE) {
        $value['type'] = 'inline';
      } else if ($type == DifferentialTransaction::TYPE_UPDATE) {
        $value['type'] = 'update';
        $value['diffId'] = idx($diff_phid_to_id, $xaction->getNewValue());
      } else if ($type == PhabricatorTransactions::TYPE_COMMENT) {
        $value['type'] = 'comment';
      } else if (array_key_exists($type, $type_action_map)) {
        $value['type'] = $type_action_map[$type];
      }

      if ($xaction->hasComment()) {
        $comment = $xaction->getComment();
        $value['comment'] = $comment->getContent();

        // src/applications/differential/storage/DifferentialInlineComment.php
        if ($type == DifferentialTransaction::TYPE_INLINE) {
          $value['replyTo'] = idx(
            $comment_phid_to_xaction_id, $comment->getReplyToCommentPHID());
          $value['isNewFile'] = $comment->getIsNewFile();
          // Also get the file name and line number
          $value['line'] = $comment->getLineNumber();
          $value['lineLength'] = $comment->getLineLength();
          $changeset = idx($changesets, $comment->getChangesetID());
          if ($changeset) {
            $value['path'] = $changeset->getDisplayFilename();
            // Also get the diff ID
            $value['diffId'] = $changeset->getDiffID();
          }
        }
      }

      if (array_key_exists('type', $value)) {
        $value['author'] = $phid_author_map[$xaction->getAuthorPHID()];
        $value['id'] = $xaction->getID();
        $value['dateCreated'] = $xaction->getDateCreated();
        $value['dateModified'] = $xaction->getDateModified();
        $results[$revision->getID()][] = $value;
      }
    }

    return $results;
  }

  static protected function loadDependsOn(
    PhabricatorUser $viewer,
    array $revisions) { // return {$revision_id => [$depends_on_id]}
    assert_instances_of($revisions, 'DifferentialRevision');
    if (!$revisions) {
      return array();
    }

    $phid_revision_map = mpull($revisions, null, 'getPHID');

    $edge_types = array(
      DifferentialRevisionDependsOnRevisionEdgeType::EDGECONST,
    );

    $query = id(new PhabricatorEdgeQuery())
      ->withSourcePHIDs(array_keys($phid_revision_map))
      ->withEdgeTypes($edge_types);

    $query->execute();

    $results = array();
    foreach ($revisions as $revision) {
      $depends_on_phids = $query->getDestinationPHIDs(
        array($revision->getPHID()),
        $edge_types
      );
      $depends_on_ids = array();
      foreach ($depends_on_phids as $depends_on_phid) {
        if (array_key_exists($depends_on_phid, $phid_revision_map)) {
          $depends_on_ids[] = $phid_revision_map[$depends_on_phid]->getID();
        }
      }
      $results[$revision->getID()] = $depends_on_ids;
    }
    return $results;
  }

  static protected function loadInlineChangesets(
    PhabricatorUser $viewer,
    array $xactions) { // return {$changeset_id => $changeset}
    assert_instances_of($xactions, 'DifferentialTransaction');

    $inlines = array();
    foreach ($xactions as $xaction) {
      if ($xaction->getTransactionType() ==
          DifferentialTransaction::TYPE_INLINE) {
        $inlines[] = $xaction;
      }
    }

    $changeset_ids = array();
    foreach ($inlines as $inline) {
      $changeset_ids[] = $inline->getComment()->getChangesetID();
    }

    if ($changeset_ids) {
      $changesets = id(new DifferentialChangesetQuery())
        ->setViewer($viewer)
        ->withIDs($changeset_ids)
        ->execute();
      return mpull($changesets, null, 'getID');
      // return id(new DifferentialChangeset())->loadAllWhere(
      //   'id IN (%Ld)', $changeset_ids);
    } else {
      return array();
    }
  }

  static protected function loadAuthorNameMap(
    PhabricatorUser $viewer,
    array $author_phids,
    array &$profile_map) { // return {$phid => $name}
    if (!$author_phids) {
      return array();
    }
    $authors = id(new PhabricatorPeopleQuery())
      ->setViewer($viewer)
      ->needProfileImage(true)
      ->withPHIDs($author_phids)
      ->execute();
    foreach ($authors as $author) {
      $profile_map[$author->getUserName()] = $author;
    }
    return mpull($authors, 'getUserName', 'getPHID');
  }

  static protected function mapPHIDstoNames(array $phid_name_map, array $phids) {
    $result = array();
    foreach ($phids as $phid) {
      $name = idx($phid_name_map, $phid);
      if ($name) {
        $result[] = $name;
      }
    }
    return $result;
  }
}
