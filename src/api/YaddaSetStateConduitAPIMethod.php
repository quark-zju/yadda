<?php

final class YaddaSetStateConduitAPIMethod extends ConduitAPIMethod {

  public function getAPIMethodName() {
    return 'yadda.setstate';
  }

  public function shouldRequireAuthentication() {
    return true;
  }

  public function getMethodDescription() {
    return pht('Store state associated to the user.');
  }

  protected function defineParamTypes() {
    return array(
      'data' => 'optional string',
    );
  }

  protected function defineReturnType() {
    return 'void';
  }

  protected function execute(ConduitAPIRequest $request) {
    $viewer = $request->getUser();
    $value = $request->getValue('data');
    YaddaUserState::set($viewer, $value);
  }
}
