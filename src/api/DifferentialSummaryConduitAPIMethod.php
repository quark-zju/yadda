<?php

final class DifferentialSummaryConduitAPIMethod extends ConduitAPIMethod {

  public function getAPIMethodName() {
    return 'differential.summary';
  }

  public function shouldRequireAuthentication() {
    return true;
  }

  public function getMethodDescription() {
    return pht('Get metadata about Differential Revisions. '.
      'If no `ids` are provided, return all open revisions.');
  }

  protected function defineParamTypes() {
    return array(
      'ids' => 'optional list<int>',
    );
  }

  protected function defineReturnType() {
    return 'dict';
  }

  protected function execute(ConduitAPIRequest $request) {
    $viewer = $request->getUser();
    $query = id(new DifferentialRevisionQuery())
      ->setViewer($viewer)
      ->needReviewers(true);
    $ids = $request->getValue('ids', array());
    if ($ids) {
      $query->withIDs($ids);
    } else {
      $query->withStatus(DifferentialRevisionQuery::STATUS_OPEN);
    }
    $revisions = $query->execute();

    // Collecting profile images, key: username, value: URL
    $image_map = array();

    // Details of revisions
    $xactions_map = $this->loadTransactions($viewer, $revisions, $image_map);
    $depends_on_map = $this->loadDependsOn($viewer, $revisions);
    $ccs_map = id(new PhabricatorSubscribersQuery())
      ->withObjectPHIDs(mpull($revisions, 'getPHID'))
      ->execute();
    $repos = id(new PhabricatorRepositoryQuery())
      ->setViewer($viewer)
      ->withPHIDs(mpull($revisions, 'getRepositoryPHID'))
      ->execute();
    $phid_callsign_map = mpull($repos, 'getCallsign', 'getPHID');

    // Collect all author PHIDs and prepare to convert them to names
    $phids = array_merge(
      mpull($revisions, 'getAuthorPHID'),
      array_mergev(mpull($revisions, 'getReviewerPHIDs')),
      array_mergev(array_values($ccs_map)));
    $phid_author_map = $this->loadAuthorNameMap($viewer, $phids, $image_map);
    
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
        'status'       =>
          ArcanistDifferentialRevisionStatus::getNameForRevisionStatus(
            $revision->getStatus()),
        'summary'      => $revision->getSummary(),
        'testPlan'     => $revision->getTestPlan(),
        'lineCount'    => $revision->getLineCount(),
        'dependsOn'    => $depends_on_map[$id],
        'reviewers'    => $this->mapPHIDstoNames(
          $phid_author_map, $revision->getReviewerPHIDs()),
        'ccs'          => $this->mapPHIDstoNames(
          $phid_author_map, idx($ccs_map, $phid, array())),
        'actions'      => $xactions_map[$id],
        'dateCreated'  => $revision->getDateCreated(),
        'dateModified' => $revision->getDateModified(),
      );
      $revision_descs[] = $desc;
    }

    $image_descs = array();
    foreach ($image_map as $name => $uri) {
      $image_descs[] = array('name' => $name, 'uri' => $uri);
    }

    return array('revisions' => $revision_descs, 'images' => $image_descs);
  }

  protected function loadTransactions(
    PhabricatorUser $viewer,
    array $revisions,
    array &$image_map) { // return {$revision_id => [$action]}
    assert_instances_of($revisions, 'DifferentialRevision');

    $phid_revision_map = mpull($revisions, null, 'getPHID');

    $xactions = id(new DifferentialTransactionQuery())
      ->setViewer($viewer)
      ->withObjectPHIDs(mpull($revisions, 'getPHID'))
      ->needComments(true)
      ->execute();

    $phids = mpull($xactions, 'getAuthorPHID');
    $phid_author_map = $this->loadAuthorNameMap($viewer, $phids, $image_map);
    
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
      } else if ($type == PhabricatorTransactions::TYPE_COMMENT) {
        $value['type'] = 'comment';
      } else if (array_key_exists($type, $type_action_map)) {
        $value['type'] = $type_action_map[$type];
      }

      if ($xaction->hasComment()) {
        $value['comment'] = $xaction->getComment()->getContent();
      }

      if (array_key_exists('type', $value)) {
        $value['author'] = $phid_author_map[$xaction->getAuthorPHID()];
        $value['dateCreated'] = $xaction->getDateCreated();
        $value['dateModified'] = $xaction->getDateModified();
        $results[$revision->getID()][] = $value;
      }
    }

    return $results;
  }

  protected function loadDependsOn(
    PhabricatorUser $viewer,
    array $revisions) { // return {$revision_id => [$depends_on_id]}
    assert_instances_of($revisions, 'DifferentialRevision');

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

  protected function loadAuthorNameMap(
    PhabricatorUser $viewer,
    array $author_phids,
    array &$image_map) { // return {$phid => $name}
    $authors = id(new PhabricatorPeopleQuery())
      ->setViewer($viewer)
      ->needProfileImage(true)
      ->withPHIDs($author_phids)
      ->execute();
    foreach ($authors as $author) {
      $image_map[$author->getUserName()] = $author->getProfileImageURI();
    }
    return mpull($authors, 'getUserName', 'getPHID');
  }

  protected function mapPHIDstoNames(array $phid_name_map, array $phids) {
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