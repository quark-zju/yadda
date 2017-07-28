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
    return 'list<dict>';
  }

  protected function execute(ConduitAPIRequest $request) {
    $viewer = $request->getUser();
    $query = id(new DifferentialRevisionQuery())->setViewer($viewer);
    $ids = $request->getValue('ids', array());
    if ($ids) {
      $query->withIDs($ids);
    } else {
      $query->withStatus(DifferentialRevisionQuery::STATUS_OPEN);
    }
    $revisions = $query->execute();

    $depends_on_map = $this->loadDependsOn($viewer, $revisions);
    $xactions = $this->loadTransactions($viewer, $revisions);
    $phid_author_map = $this->loadAuthorNameMap($viewer, $revisions);
    
    $results = array();
    foreach ($revisions as $revision) {
      $id = $revision->getID();
      $result = array(
        'id'           => $id,
        'title'        => $revision->getTitle(),
        'author'       => $phid_author_map[$revision->getAuthorPHID()],
        'status'       =>
          ArcanistDifferentialRevisionStatus::getNameForRevisionStatus(
            $revision->getStatus()),
        'summary'      => $revision->getSummary(),
        'testPlan'     => $revision->getTestPlan(),
        'lineCount'    => $revision->getLineCount(),
        'dependsOn'    => $depends_on_map[$id],
        'actions'      => $xactions[$id],
        'dateCreated'  => $revision->getDateCreated(),
        'dateModified' => $revision->getDateModified(),
      );
      $results[] = $result;
    }

    return $results;
  }

  protected function loadTransactions(
    PhabricatorUser $viewer,
    array $revisions) { // return {$revision_id => [$action]}
    assert_instances_of($revisions, 'DifferentialRevision');

    $phid_revision_map = mpull($revisions, null, 'getPHID');

    $xactions = id(new DifferentialTransactionQuery())
      ->setViewer($viewer)
      ->withObjectPHIDs(mpull($revisions, 'getPHID'))
      ->needComments(true)
      ->execute();

    $phid_author_map = $this->loadAuthorNameMap($viewer, $xactions);
    
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
    array $list) { // return {$phid => $name}
    $author_phids = array_unique(mpull($list, 'getAuthorPHID'));
    $authors = id(new PhabricatorHandleQuery())
      ->setViewer($viewer)
      ->withPHIDs($author_phids)
      ->execute();
    return mpull($authors, 'getName', 'getPHID');
  }
}
