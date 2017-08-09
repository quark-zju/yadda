<?php

final class YaddaSQLPatchList extends PhabricatorSQLPatchList {

  public function getNamespace() {
    return 'yadda';
  }

  public function getPatches() {
    $root = (phutil_get_library_root('yadda')).'/db/migrate';
    $patches = array(
      'db.yadda' => array(
        'after' => array(),
        'name' => 'yadda',
        'type' => 'db',
      ),
    );
    $patches += $this->buildPatchesFromDirectory($root);
    return $patches;
  }

}
