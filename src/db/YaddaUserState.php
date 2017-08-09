<?php

final class YaddaUserState extends PhabricatorLiskDAO {

  protected $userPHID;
  protected $value;

  private $shouldInsert;

  public function __construct() {
    parent::__construct();
    $this->shouldInsert = true;
  }

  public function getApplicationName() {
    return 'yadda';
  }

  protected function getConfiguration() {
    return array(
      self::CONFIG_IDS => self::IDS_MANUAL,
      self::CONFIG_TIMESTAMPS => false,
      self::CONFIG_COLUMN_SCHEMA => array(
        'userPHID' => 'phid',
        'value' => 'text',
      ),
      self::CONFIG_KEY_SCHEMA => array(
        'userPHID' => array(
          'columns' => array('userPHID'),
          'unique' => true,
        ),
      ),
    );
  }

  protected function shouldInsertWhenSaved() {
    return $this->shouldInsert;
  }

  public function getIDKey() {
    return 'userPHID';
  }

  public function load(PhabricatorUser $user) {
    $phid = $user->getPHID();
    $state = $this->loadOneWhere('%C = %s', $this->getIDKeyForUse(), $phid);
    if (!$state) {
      $state = $this->setUserPHID($phid);
      $state->shouldInsert = true;
    } else {
      $state->shouldInsert = false;
    }
    return $state;
  }

  public function delete() {
    if (!$this->shouldInsert) {
      $conn = $this->establishConnection('w');
      $this->willDelete();
      $conn->query(
        'DELETE FROM %T WHERE %C = %s',
        $this->getTableName(),
        $this->getIDKeyForUse(),
        $this->getID());
      $this->didDelete();
    }
    return $this;
  }

  public static function get(PhabricatorUser $user) {
    return id(new YaddaUserState)->load($user)->getValue();
  }

  public static function set(PhabricatorUser $user, /* ?string */ $value) {
    $state = id(new YaddaUserState)->load($user);
    if ($value) {
      $state->setValue($value)->save();
    } else {
      $state->delete();
    }
  }

}
