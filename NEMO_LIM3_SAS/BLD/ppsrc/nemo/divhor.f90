MODULE divhor
!!==============================================================================
!!                       ***  MODULE  divhor  ***
!! Ocean diagnostic variable : now horizontal divergence
!!==============================================================================
!! History :  1.0  ! 2002-09  (G. Madec, E. Durand)  Free form, F90
!!             -   ! 2005-01  (J. Chanut) Unstructured open boundaries
!!             -   ! 2003-08  (G. Madec)  merged of cur and div, free form, F90
!!             -   ! 2005-01  (J. Chanut, A. Sellar) unstructured open boundaries
!!            3.3  ! 2010-09  (D.Storkey and E.O'Dea) bug fixes for BDY module
!!             -   ! 2010-10  (R. Furner, G. Madec) runoff and cla added directly here
!!            3.7  ! 2014-01  (G. Madec) suppression of velocity curl from in-core memory
!!             -   ! 2014-12  (G. Madec) suppression of cross land advection option
!!             -   ! 2015-10  (G. Madec) add velocity and rnf flag in argument of div_hor
!!----------------------------------------------------------------------

!!----------------------------------------------------------------------
!!   div_hor    : Compute the horizontal divergence field
!!----------------------------------------------------------------------
   USE oce             ! ocean dynamics and tracers
   USE dom_oce         ! ocean space and time domain
   USE sbc_oce, ONLY : ln_rnf, ln_isf ! surface boundary condition: ocean
   USE sbcrnf          ! river runoff
   USE sbcisf          ! ice shelf
   USE iscplhsb        ! ice sheet / ocean coupling
   USE iscplini        ! ice sheet / ocean coupling
!
   USE in_out_manager  ! I/O manager
   USE lbclnk          ! ocean lateral boundary conditions (or mpp link)
   USE lib_mpp         ! MPP library
   USE wrk_nemo        ! Memory Allocation
   USE timing          ! Timing

   IMPLICIT NONE
   PRIVATE

   PUBLIC   div_hor    ! routine called by step.F90 and istate.F90

!! * Substitutions
!!----------------------------------------------------------------------
!!                   ***  vectopt_loop_substitute  ***
!!----------------------------------------------------------------------
!! ** purpose :   substitute the inner loop start/end indices with CPP macro
!!                allow unrolling of do-loop (useful with vector processors)
!!----------------------------------------------------------------------
!!----------------------------------------------------------------------
!! NEMO/OPA 3.7 , NEMO Consortium (2014)
!! $Id: vectopt_loop_substitute.h90 4990 2014-12-15 16:42:49Z timgraham $
!! Software governed by the CeCILL licence (NEMOGCM/NEMO_CeCILL.txt)
!!----------------------------------------------------------------------




!!----------------------------------------------------------------------
!! NEMO/OPA 3.7 , NEMO Consortium (2014)
!! $Id: divhor.F90 7753 2017-03-03 11:46:59Z mocavero $
!! Software governed by the CeCILL licence     (NEMOGCM/NEMO_CeCILL.txt)
!!----------------------------------------------------------------------
CONTAINS

   SUBROUTINE div_hor( kt )
!!----------------------------------------------------------------------
!!                  ***  ROUTINE div_hor  ***
!!
!! ** Purpose :   compute the horizontal divergence at now time-step
!!
!! ** Method  :   the now divergence is computed as :
!!         hdivn = 1/(e1e2t*e3t) ( di[e2u*e3u un] + dj[e1v*e3v vn] )
!!      and correct with runoff inflow (div_rnf) and cross land flow (div_cla)
!!
!! ** Action  : - update hdivn, the now horizontal divergence
!!----------------------------------------------------------------------
      INTEGER, INTENT(in) ::   kt   ! ocean time-step index
!
      INTEGER  ::   ji, jj, jk    ! dummy loop indices
      REAL(wp) ::   zraur, zdep   ! local scalars
!!----------------------------------------------------------------------
!
      IF( nn_timing == 1 )   CALL timing_start('div_hor')
!
      IF( kt == nit000 ) THEN
         IF(lwp) WRITE(numout,*)
         IF(lwp) WRITE(numout,*) 'div_hor : horizontal velocity divergence '
         IF(lwp) WRITE(numout,*) '~~~~~~~   '
      ENDIF
!
      DO jk = 1, jpkm1                                      !==  Horizontal divergence  ==!
         DO jj = 2, jpjm1
            DO ji = 2, jpim1   ! vector opt.
               hdivn(ji,jj,jk) = (  e2u(ji  ,jj) * e3u_n(ji  ,jj,jk) * un(ji  ,jj,jk)        &
                  &               - e2u(ji-1,jj) * e3u_n(ji-1,jj,jk) * un(ji-1,jj,jk)        &
                  &               + e1v(ji,jj  ) * e3v_n(ji,jj  ,jk) * vn(ji,jj  ,jk)        &
                  &               - e1v(ji,jj-1) * e3v_n(ji,jj-1,jk) * vn(ji,jj-1,jk)   )    &
                  &            / ( e1e2t(ji,jj) * e3t_n(ji,jj,jk) )
            END DO  
         END DO  
         IF( .NOT. AGRIF_Root() ) THEN
            IF( nbondi ==  1 .OR. nbondi == 2 )   hdivn(nlci-1,   :  ,jk) = 0._wp      ! east
            IF( nbondi == -1 .OR. nbondi == 2 )   hdivn(  2   ,   :  ,jk) = 0._wp      ! west
            IF( nbondj ==  1 .OR. nbondj == 2 )   hdivn(  :   ,nlcj-1,jk) = 0._wp      ! north
            IF( nbondj == -1 .OR. nbondj == 2 )   hdivn(  :   ,  2   ,jk) = 0._wp      ! south
         ENDIF
      END DO
!
      IF( ln_rnf )   CALL sbc_rnf_div( hdivn )      !==  runoffs    ==!   (update hdivn field)
!
      IF( ln_isf )   CALL sbc_isf_div( hdivn )      !==  ice shelf  ==!   (update hdivn field)
!
      IF( ln_iscpl .AND. ln_hsb ) CALL iscpl_div( hdivn )  !==  ice sheet  ==!   (update hdivn field)
!
      CALL lbc_lnk( hdivn, 'T', 1. )                !==  lateral boundary cond.  ==!   (no sign change)
!
      IF( nn_timing == 1 )  CALL timing_stop('div_hor')
!
   END SUBROUTINE div_hor
   
!!======================================================================
END MODULE divhor
