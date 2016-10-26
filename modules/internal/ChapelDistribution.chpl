/*
 * Copyright 2004-2016 Cray Inc.
 * Other additional copyright holders may be indicated within.
 * 
 * The entirety of this work is licensed under the Apache License,
 * Version 2.0 (the "License"); you may not use this file except
 * in compliance with the License.
 * 
 * You may obtain a copy of the License at
 * 
 *     http://www.apache.org/licenses/LICENSE-2.0
 * 
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

module ChapelDistribution {

  use List;

  extern proc chpl_task_yield();

  //
  // Abstract distribution class
  //
  pragma "base dist"
  class BaseDist {
    // The common case seems to be local access to this class, so we
    // will use explicit processor atomics, even when network
    // atomics are available
    var _doms: list(BaseDom);     // domains declared over this distribution
    var _domsLock: atomicbool;    //   and lock for concurrent access
    var _free_when_no_doms: bool; // true when the original _distribution
                                  // has been destroyed
    var pid:int = nullPid; // privatized ID, if privatization is supported
  
    proc ~BaseDist() {
    }

    // Returns a distribution that should be freed or nil.
    pragma "dont disable remote value forwarding"
    proc remove(): BaseDist {
      var free_dist = false;
      if dsiTrackDomains() {
        on this {
          var dom_count = -1;
          local {
            _lock_doms();
            // Set a flag to indicate it should be freed when _doms
            // becomes empty
            _free_when_no_doms = true;
            dom_count = _doms.size;
            _unlock_doms();
          }
          if dom_count == 0 then
            free_dist = true;
        }
      } else {
        // if we're not tracking domains, always free the
        // distribution when it goes out of scope.
        free_dist = true;
      }
      if free_dist then
        return this;
      else
        return nil;
    }

    // Returns true if the distribution should be removed.
    inline proc remove_dom(x:BaseDom): bool {
      var count = -1;
      on this {
        var cnt = -1;
        local {
          _lock_doms();
          _doms.remove(x);
          cnt = _doms.size;

          // add one for the main distribution instance
          if !_free_when_no_doms then
            cnt += 1;

          _unlock_doms();
        }
        count = cnt;
      }
      return (count==0);
    }

    inline proc add_dom(x:BaseDom) {
      on this {
        _lock_doms();
        _doms.append(x);
        _unlock_doms();
      }
    }
  
    inline proc _lock_doms() {
      // WARNING: If you are calling this function directly from
      // a remote locale, you should consider wrapping the call in
      // an on clause to avoid excessive remote forks due to the
      // testAndSet()
      while (_domsLock.testAndSet()) do chpl_task_yield();
    }
  
    inline proc _unlock_doms() {
      _domsLock.clear();
    }
  
    proc dsiNewRectangularDom(param rank: int, type idxType, param stridable: bool) {
      compilerError("rectangular domains not supported by this distribution");
    }
  
    proc dsiNewAssociativeDom(type idxType, param parSafe: bool) {
      compilerError("associative domains not supported by this distribution");
    }
  
    proc dsiNewAssociativeDom(type idxType, param parSafe: bool)
    where isEnumType(idxType) {
      compilerError("enumerated domains not supported by this distribution");
    }
  
    proc dsiNewOpaqueDom(type idxType, param parSafe: bool) {
      compilerError("opaque domains not supported by this distribution");
    }
  
    proc dsiNewSparseDom(param rank: int, type idxType, dom: domain) {
      compilerError("sparse domains not supported by this distribution");
    }
  
    proc dsiSupportsPrivatization() param return false;
    proc dsiRequiresPrivatization() param return false;
  
    proc dsiDestroyDist() { }
  
    proc dsiDisplayRepresentation() { }

    // Does the distribution keep a list of domains? Can the domains
    // keep the distribution alive longer? false for DefaultDist.
    proc trackDomains() param return true;

    // dynamically-dispatched counterpart of linksDistribution
    proc dsiTrackDomains() return true;

    // indicates if a distribution is a singleton. If so, we make no
    // effort to free it. DefaultDist is a singleton.
    proc singleton() param return false;
    // We could add dsiSingleton as a dynamically-dispatched counterpart
  }
  
  //
  // Abstract domain classes
  //
  pragma "base domain"
  class BaseDom {
    // The common case seems to be local access to this class, so we
    // will use explicit processor atomics, even when network
    // atomics are available
    var _arrs: list(BaseArr);  // arrays declared over this domain
    var _arrs_containing_dom: int; // number of arrays using this domain
                                   // as var A: [D] [1..2] real
                                   // is using {1..2}
    var _arrsLock: atomicbool; //   and lock for concurrent access
    var _free_when_no_arrs: bool;
    var pid:int = nullPid; // privatized ID, if privatization is supported
  
    proc ~BaseDom() {
    }

    proc dsiMyDist(): BaseDist {
      halt("internal error: dsiMyDist is not implemented");
      return nil;
    }
  
    // Returns (dom, dist).
    // if this domain should be deleted, dom=this; otherwise it is nil.
    // dist is nil or a distribution that should be removed.
    pragma "dont disable remote value forwarding"
    proc remove() : (BaseDom, BaseDist) {

      // TODO -- remove dsiLinksDistribution
      assert( dsiMyDist().dsiTrackDomains() == dsiLinksDistribution() );

      var ret_dom:BaseDom = nil;
      var ret_dist:BaseDist = nil;
      var dist = dsiMyDist();
      var free_dom = false;
      var remove_dist = false;
      on this {
        var arr_count = 0;
        // Count the number of arrays using this domain
        // and mark this domain to free itself when that number reaches 0.
        local {
          _lock_arrs();
          arr_count = _arrs.size;
          arr_count += _arrs_containing_dom;
          _free_when_no_arrs = true;
          _unlock_arrs();
        }

        if arr_count == 0 {
          free_dom = true;

          if dsiLinksDistribution() {
            // Remove the domain from the distribution
            // and find out if the distribution should be removed.
            remove_dist = dist.remove_dom(this);
          }
        }
      }
      if free_dom then
        ret_dom = this; // caller will delete this
      if remove_dist then
        ret_dist = dist; // caller will remove dist
      return (ret_dom, ret_dist);
    }

    // returns true if the domain should be removed
    inline proc remove_arr(x:BaseArr): bool {
      var count = -1;
      on this {
        var cnt = -1;
        local {
          _lock_arrs();
          _arrs.remove(x);
          cnt = _arrs.size;
          cnt += _arrs_containing_dom;
          // add one for the main domain record
          if !_free_when_no_arrs then
            cnt += 1;
          _unlock_arrs();
        }
        count = cnt;
      }
      return (count==0);
    }
  
    inline proc add_arr(x:BaseArr, param locking=true) {
      on this {
        if locking then
          _lock_arrs();
        _arrs.append(x);
        if locking then
          _unlock_arrs();
      }
    }
  
    inline proc remove_containing_arr(x:BaseArr): int {
      var count = -1;
      on this {
        _lock_arrs();
        _arrs_containing_dom -= 1;
        count = _arrs.size;
        count += _arrs_containing_dom;
        _unlock_arrs();
      }
      return count;
    }

    inline proc add_containing_arr(x:BaseArr) {
      on this {
        _lock_arrs();
        _arrs_containing_dom += 1;
        _unlock_arrs();
      }
    }

    inline proc _lock_arrs() {
      // WARNING: If you are calling this function directly from
      // a remote locale, you should consider wrapping the call in
      // an on clause to avoid excessive remote forks due to the
      // testAndSet()
      while (_arrsLock.testAndSet()) do chpl_task_yield();
    }
  
    inline proc _unlock_arrs() {
      _arrsLock.clear();
    }
  
    // used for associative domains/arrays
    proc _backupArrays() {
      for arr in _arrs do
        arr._backupArray();
    }
  
    proc _removeArrayBackups() {
      for arr in _arrs do
        arr._removeArrayBackup();
    }
  
    proc _preserveArrayElements(oldslot, newslot) {
      for arr in _arrs do
        arr._preserveArrayElement(oldslot, newslot);
    }
  
    proc dsiSupportsPrivatization() param return false;
    proc dsiRequiresPrivatization() param return false;
  
    // Does the distribution keep a list of domains? Can the
    // domains keep the distribution alive longer?
    proc linksDistribution() param return true;
  
    // dynamically-dispatched counterpart of linksDistribution
    proc dsiLinksDistribution() return true;

    // Overload to to customize domain destruction
    proc dsiDestroyDom() { }

    proc dsiDisplayRepresentation() { }
  }
  
  class BaseRectangularDom : BaseDom {
    proc ~BaseRectangularDom() {
      // this is a bug workaround
    }

    proc dsiClear() {
      halt("clear not implemented for this distribution");
    }
  
    proc dsiAdd(x) {
      compilerError("Cannot add indices to a rectangular domain");
      return 0;
    }
  
    proc dsiRemove(x) {
      compilerError("Cannot remove indices from a rectangular domain");
      return 0;
    }
  }
  
  class BaseSparseDomImpl : BaseSparseDom {

    var nnzDom = {1..nnz};

    proc ~BaseSparseDomImpl() {
      // this is a bug workaround
    }

    proc dsiBulkAdd(inds: [] index(rank, idxType),
        dataSorted=false, isUnique=false, preserveInds=true){

      if !dataSorted && preserveInds {
        var _inds = inds;
        return bulkAdd_help(_inds, dataSorted, isUnique); 
      }
      else {
        return bulkAdd_help(inds, dataSorted, isUnique);
      }
    }

    proc bulkAdd_help(inds: [?indsDom] index(rank, idxType), 
        dataSorted=false, isUnique=false){
      halt("Helper function called on the BaseSparseDomImpl");

      return -1;
    }

    inline proc _grow(size: int){
      const oldNNZDomSize = nnzDom.size;
      if (size > oldNNZDomSize) {
        const _newNNZDomSize = if (oldNNZDomSize) then 2*oldNNZDomSize else 1;
        nnzDom = {1.._newNNZDomSize};
      }
    }

    inline proc _bulkGrow(size: int) {
      if (nnz > nnzDom.size) {
        const _newNNZDomSize = (exp2(log2(nnz)+1.0)):int;

        nnzDom = {1.._newNNZDomSize};
      }
    }

    // this is a helper function for bulkAdd functions in sparse subdomains.
    // NOTE:it assumes that nnz array of the sparse domain has non-negative 
    // indices. If, for some reason it changes, this function and bulkAdds have to
    // be refactored. (I think it is a safe assumption at this point and keeps the
    // function a bit cleaner than some other approach. -Engin)
    proc __getActualInsertPts(d, inds, 
        dataSorted, isUnique) /* where isSparseDom(d) */ {

      use Sort;

      //find individual insert points
      //and eliminate duplicates between inds and dom
      var indivInsertPts: [inds.domain] int;
      var actualInsertPts: [inds.domain] int; //where to put in newdom

      if !dataSorted then sort(inds);

      //eliminate duplicates --assumes sorted
      if !isUnique {
        //make sure lastInd != inds[inds.domain.low]
        var lastInd = inds[inds.domain.low] + 1; 
        for (i, p) in zip(inds, indivInsertPts)  {
          if i == lastInd then p = -1;
          else lastInd = i;
        }
      }

      //verify sorted and no duplicates if not --fast
      if boundsChecking {
        if !isSorted(inds) then
          halt("bulkAdd: Data not sorted, call the function with dataSorted=false");

        //check duplicates assuming sorted
        const indsStart = inds.domain.low;
        const indsEnd = inds.domain.high;
        var lastInd = inds[indsStart];
        for i in indsStart+1..indsEnd {
          if inds[i] == lastInd && indivInsertPts[i] != -1 then 
            halt("There are duplicates, call the function with isUnique=false"); 
        }

        for i in inds do d.boundsCheck(i);

      }

      forall (i,p) in zip(inds, indivInsertPts) {
        if isUnique || p != -1 { //don't do anything if it's duplicate
          const (found, insertPt) = d.find(i);
          p = if found then -1 else insertPt; //mark as duplicate
        }
      }

      //shift insert points for bulk addition
      //previous indexes that are added will cause a shift in the next indexes
      var actualAddCnt = 0;

      //NOTE: this can also be done with scan
      for (ip, ap) in zip(indivInsertPts, actualInsertPts) {
        if ip != -1 {
          ap = ip + actualAddCnt;
          actualAddCnt += 1;
        }
        else ap = ip;
      }

      return (actualInsertPts, actualAddCnt);
    }

    proc dsiClear(){
      halt("not implemented");
    }

  }

  class BaseSparseDom : BaseDom {
    // rank and idxType will be moved to BaseDom
    param rank: int;
    type idxType;
    var parentDom;

    // We currently cannot have dist here. It is due to a compiler bug due to
    // inheritance of generic var fields.
    // var dist;

    var nnz = 0; //: int;

    proc ~BaseSparseDom() {
      // this is a bug workaround
    }

    proc dsiClear() {
      halt("clear not implemented for this distribution - BaseSparseDom");
    }
  
    proc dsiBulkAdd(inds: [] index(rank, idxType),
        dataSorted=false, isUnique=false, preserveInds=true){

      halt("Bulk addition is not supported by this sparse domain");
    }

    proc boundsCheck(ind: index(rank, idxType)):void {
      if boundsChecking then
        if !(parentDom.member(ind)) then
          halt("Sparse domain/array index out of bounds: ", ind,
              " (expected to be within ", parentDom, ")");
    }

    //basic DSI functions
    proc dsiDim(d: int) { return parentDom.dim(d); }
    proc dsiDims() { return parentDom.dims(); }
    proc dsiNumIndices { return nnz; }
    proc dsiSize { return nnz; }
    proc dsiLow { return parentDom.low; }
    proc dsiHigh { return parentDom.high; }
    proc dsiStride { return parentDom.stride; }
    proc dsiAlignment { return parentDom.alignment; }
    proc dsiFirst {
      halt("dsiFirst is not implemented");
      const _tmp: rank*idxType;
      return _tmp;
    }
    proc dsiLast {
      halt("dsiLast not implemented");
      const _tmp: rank*idxType;
      return _tmp;
    }
    proc dsiAlignedLow { return parentDom.alignedLow; }
    proc dsiAlignedHigh { return parentDom.alignedHigh; }

  } // end BaseSparseDom

  // BaseSparseDom operator overloads
  proc +=(ref sd: domain, inds: [] sd.idxType) where isSparseDom(sd) && 
    sd.rank==1 {

    if inds.size == 0 then return;

    sd._value.dsiBulkAdd(inds);
  }

  proc +=(ref sd: domain, inds: [] sd.rank*sd.idxType) where isSparseDom(sd) &&
    sd.rank>1 {

    if inds.size == 0 then return;

    sd._value.dsiBulkAdd(inds);
  }

  // Currently this is not optimized for addition of a sparse
  proc +=(ref sd: domain, d: domain)
  where isSparseDom(sd) && d.rank==sd.rank && sd.idxType==d.idxType {

    if d.size == 0 then return;

    type _idxType = if sd.rank==1 then int else sd.rank*int;
    const indCount = d.numIndices;
    const arr: [{0..#indCount}] _idxType;

    //this could be a parallel loop. but ranks don't match -- doesn't compile
    for (a,i) in zip(arr,d) do a=i;

    sd._value.dsiBulkAdd(arr, true, true, false);
  }
  // end BaseSparseDom operators
  
  class BaseAssociativeDom : BaseDom {
    proc ~BaseAssociativeDom() {
      // this is a bug workaround
    }

    proc dsiClear() {
      halt("clear not implemented for this distribution");
    }

    proc dsiAdd(idx) {
      compilerError("Index addition is not supported by this domain");
      return 0;
    }
  
  }
  
  class BaseOpaqueDom : BaseDom {
    proc ~BaseOpaqueDom() {
      // this is a bug workaround
    }

    proc dsiClear() {
      halt("clear not implemented for this distribution");
    }
  
  }
  
  //
  // Abstract array class
  //
  pragma "base array"
  class BaseArr {
    // The common case seems to be local access to this class, so we
    // will use explicit processor atomics, even when network
    // atomics are available
    var _arrAlias: BaseArr;    // reference to base array if an alias
    var pid:int = nullPid; // privatized ID, if privatization is supported
  
    proc ~BaseArr() {
    }

    proc dsiStaticFastFollowCheck(type leadType) param return false;
  
    proc dsiGetBaseDom(): BaseDom {
      halt("internal error: dsiGetBaseDom is not implemented");
      return nil;
    }
  
    // returns (arr, dom)
    // arr is this if it should be deleted, or nil.
    // dom is a domain that should be removed, or nil.
    pragma "dont disable remote value forwarding"
    proc remove() {
      var ret_arr = this; // this array is always deleted
      var ret_dom:BaseDom = nil;
      var rm_dom = false;

      var dom = dsiGetBaseDom();
      // Remove the array from the domain
      // and find out if the domain should be removed.
      rm_dom = dom.remove_arr(this);

      if rm_dom then
        ret_dom = dom;

      return (ret_arr, ret_dom);
    }
  
    proc dsiDestroyArr(isalias:bool) { }
  
    proc dsiReallocate(d: domain) {
      halt("reallocating not supported for this array type");
    }
  
    proc dsiPostReallocate() {
    }
  
    // This method is unsatisfactory -- see bradc's commit entries of
    // 01/02/08 around 14:30 for details
    proc _purge( ind: int) {
      halt("purging not supported for this array type");
    }
  
    proc _resize( length: int, old_map) {
      halt("resizing not supported for this array type");
    }
  
    //
    // Ultimately, these routines should not appear here; instead, we'd
    // like to do a dynamic cast in the sparse array class(es) that call
    // these routines in order to call them directly and avoid the
    // dynamic dispatch and leaking of this name to the class.  In order
    // to do this we'd need to hoist eltType to the base class, which
    // would require better subclassing of generic classes.  A good
    // summer project for Jonathan?
    //
    proc sparseShiftArray(shiftrange, initrange) {
      halt("sparseGrowDomain not supported for non-sparse arrays");
    }
  
    proc sparseShiftArrayBack(shiftrange) {
      halt("sparseShiftArrayBack not supported for non-sparse arrays");
    }

    proc sparseBulkShiftArray(shiftMap, oldnnz) {
      halt("sparseBulkShiftArray not supported for non-sparse arrays");
    }
  
    // methods for associative arrays
    proc clearEntry(idx, haveLock:bool = false) {
      halt("clearEntry() not supported for non-associative arrays");
    }
  
    proc _backupArray() {
      halt("_backupArray() not supported for non-associative arrays");
    }
  
    proc _removeArrayBackup() {
      halt("_removeArrayBackup() not supported for non-associative arrays");
    }
  
    proc _preserveArrayElement(oldslot, newslot) {
      halt("_preserveArrayElement() not supported for non-associative arrays");
    }
  
    proc dsiSupportsAlignedFollower() param return false;
  
    proc dsiSupportsPrivatization() param return false;
    proc dsiRequiresPrivatization() param return false;
  
    proc dsiSupportsBulkTransfer() param return false;
    proc doiCanBulkTransfer() param return false;
    proc doiBulkTransfer(B){ 
      halt("This array type does not support bulk transfer.");
    }
  
    proc dsiDisplayRepresentation() { }
    proc isDefaultRectangular() param return false;
    proc dsiSupportsBulkTransferInterface() param return false;
    proc doiCanBulkTransferStride() param return false;
  }

  /*
   * BaseSparseArr is very basic/generic so that we have some flexibility in
   * implementing sparse array classes.
   */
  class BaseSparseArr: BaseArr {
    type eltType;
    param rank : int;
    type idxType;

    var dom; /* : DefaultSparseDom(?); */

    // NOTE I tried to put `data` in `BaseSparseArrImpl`. However, it wasn't
    // clear how to initialize this in that class.
    var data: [dom.nnzDom] eltType;

    proc dsiGetBaseDom() return dom;

    proc ~BaseSparseArr() {
      // this is a bug workaround
    }
  }

  /*
   * All the common helpers/methods in implementations of internal sparse arrays
   * go here.
   */
  class BaseSparseArrImpl: BaseSparseArr {

    proc ~BaseSparseArrImpl() {
      // this is a bug workaround
    }


    // currently there is no support implemented for setting IRV for
    // SparseBlockArr, therefore I moved IRV related stuff to this class, and
    // have SparseBlockArr be a child class of BaseSparseArr directly instead
    // of this one
    var irv: eltType;
    proc IRV ref {
      return irv;
    }

    // shifts data array according to shiftMap where shiftMap[i] is the new index 
    // of the ith element of the array. Called at the end of bulkAdd to move the
    // existing items in data array and initialize new indices with irv.
    // oldnnz is the number of elements in the array. As the function is called 
    // at the end of bulkAdd, it is almost certain that oldnnz!=data.size
    proc sparseBulkShiftArray(shiftMap, oldnnz){
      var newIdx: int;
      var prevNewIdx = 1;

      // fill all new indices i s.t. i > indices[oldnnz]
      forall i in shiftMap.domain.high+1..dom.nnzDom.high do data[i] = irv;

      for (i, _newIdx) in zip(1..oldnnz by -1, shiftMap.domain.dim(1) by -1) {
        newIdx = shiftMap[_newIdx];
        data[newIdx] = data[i];

        //fill IRV up to previously added nnz
        for emptyIndex in newIdx+1..prevNewIdx-1 do data[emptyIndex] = irv;
        prevNewIdx = newIdx;
      }
      //fill the initial added space with IRV
      for i in 1..prevNewIdx-1 do data[i] = irv;
    }

    // shift data array after single index addition. Fills the new index with irv
    proc sparseShiftArray(shiftrange, initrange) {
      for i in initrange {
        data(i) = irv;
      }
      for i in shiftrange by -1 {
        data(i+1) = data(i);
      }
      data(shiftrange.low) = irv;
    }

    proc sparseShiftArrayBack(shiftrange) {
      for i in shiftrange {
        data(i) = data(i+1);
      }
    }
  }

  // delete helpers

  // param privatized here is a workaround for the fact that
  // we can't include the privatized freeing for DefaultRectangular
  // because of resolution order issues
  proc _delete_dist(dist:BaseDist, param privatized:bool) {
    dist.dsiDestroyDist();

    if privatized {
      _freePrivatizedClass(dist.pid, dist);
    }

    delete dist;
  }

  proc _delete_dom(dom:BaseDom, param privatized:bool) {
    dom.dsiDestroyDom();

    if privatized {
      _freePrivatizedClass(dom.pid, dom);
    }

    delete dom;
  }
  // arr is a subclass of :BaseArr but is generic so
  // that arr.eltType is meaningful.
  proc _delete_arr(arr, param privatized:bool) {
    // decide whether or not the array is an alias
    var isalias = (arr._arrAlias != nil);

    if !isalias {
      // unlink domain referred to by arr.eltType
      // not necessary for aliases/slices because the original
      // array will take care of it.
      chpl_decRefCountsForDomainsInArrayEltTypes(arr, arr.eltType);
    }

    // array implementation can destroy data or other members
    arr.dsiDestroyArr(isalias);

    if privatized {
      _freePrivatizedClass(arr.pid, arr);
    }

    // runs the array destructor
    delete arr;
  }
}
