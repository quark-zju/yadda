<?php

final class CelerityYaddaResources extends CelerityResourcesOnDisk {

  public function getName() {
    return 'yadda';
  }

  public function getPathToResources() {
    return $this->joinPath('../rsrc/build');
  }

  public function getPathToMap() {
    return $this->joinPath('res/map.php');
  }

  private function joinPath($to_file) {
    return (phutil_get_library_root('yadda')).'/'.$to_file;
  }

}
