MODULE dynvor
!!======================================================================
!!                       ***  MODULE  dynvor  ***
!! Ocean dynamics: Update the momentum trend with the relative and
!!                 planetary vorticity trends
!!======================================================================
!! History :  OPA  ! 1989-12  (P. Andrich)  vor_ens: Original code
!!            5.0  ! 1991-11  (G. Madec) vor_ene, vor_mix: Original code
!!            6.0  ! 1996-01  (G. Madec)  s-coord, suppress work arrays
!!   NEMO     0.5  ! 2002-08  (G. Madec)  F90: Free form and module
!!            1.0  ! 2004-02  (G. Madec)  vor_een: Original code
!!             -   ! 2003-08  (G. Madec)  add vor_ctl
!!             -   ! 2005-11  (G. Madec)  add dyn_vor (new step architecture)
!!            2.0  ! 2006-11  (G. Madec)  flux form advection: add metric term
!!            3.2  ! 2009-04  (R. Benshila)  vvl: correction of een scheme
!!            3.3  ! 2010-10  (C. Ethe, G. Madec) reorganisation of initialisation phase
!!            3.7  ! 2014-04  (G. Madec) trend simplification: suppress jpdyn_trd_dat vorticity
!!             -   ! 2014-06  (G. Madec) suppression of velocity curl from in-core memory
!!             -   ! 2016-12  (G. Madec, E. Clementi) add Stokes-Coriolis trends (ln_stcor=T)
!!----------------------------------------------------------------------

!!----------------------------------------------------------------------
!!   dyn_vor      : Update the momentum trend with the vorticity trend
!!       vor_ens  : enstrophy conserving scheme       (ln_dynvor_ens=T)
!!       vor_ene  : energy conserving scheme          (ln_dynvor_ene=T)
!!       vor_een  : energy and enstrophy conserving   (ln_dynvor_een=T)
!!   dyn_vor_init : set and control of the different vorticity option
!!----------------------------------------------------------------------
   USE oce            ! ocean dynamics and tracers
   USE dom_oce        ! ocean space and time domain
   USE dommsk         ! ocean mask
   USE dynadv         ! momentum advection (use ln_dynadv_vec value)
   USE trd_oce        ! trends: ocean variables
   USE trddyn         ! trend manager: dynamics
   USE sbcwave        ! Surface Waves (add Stokes-Coriolis force)
   USE sbc_oce , ONLY : ln_stcor    ! use Stoke-Coriolis force
!
   USE lbclnk         ! ocean lateral boundary conditions (or mpp link)
   USE prtctl         ! Print control
   USE in_out_manager ! I/O manager
   USE lib_mpp        ! MPP library
   USE wrk_nemo       ! Memory Allocation
   USE timing         ! Timing


   IMPLICIT NONE
   PRIVATE

   PUBLIC   dyn_vor        ! routine called by step.F90
   PUBLIC   dyn_vor_init   ! routine called by nemogcm.F90

!                                   !!* Namelist namdyn_vor: vorticity term
   LOGICAL, PUBLIC ::   ln_dynvor_ene   !: energy conserving scheme    (ENE)
   LOGICAL, PUBLIC ::   ln_dynvor_ens   !: enstrophy conserving scheme (ENS)
   LOGICAL, PUBLIC ::   ln_dynvor_mix   !: mixed scheme                (MIX)
   LOGICAL, PUBLIC ::   ln_dynvor_een   !: energy and enstrophy conserving scheme (EEN)
   INTEGER, PUBLIC ::      nn_een_e3f      !: e3f=masked averaging of e3t divided by 4 (=0) or by the sum of mask (=1)
   LOGICAL, PUBLIC ::   ln_dynvor_msk   !: vorticity multiplied by fmask (=T) or not (=F) (all vorticity schemes)

   INTEGER ::   nvor_scheme        ! choice of the type of advection scheme
!                               ! associated indices:
   INTEGER, PUBLIC, PARAMETER ::   np_ENE = 1   ! ENE scheme
   INTEGER, PUBLIC, PARAMETER ::   np_ENS = 2   ! ENS scheme
   INTEGER, PUBLIC, PARAMETER ::   np_MIX = 3   ! MIX scheme
   INTEGER, PUBLIC, PARAMETER ::   np_EEN = 4   ! EEN scheme

   INTEGER ::   ncor, nrvm, ntot   ! choice of calculated vorticity
!                               ! associated indices:
   INTEGER, PARAMETER ::   np_COR = 1         ! Coriolis (planetary)
   INTEGER, PARAMETER ::   np_RVO = 2         ! relative vorticity
   INTEGER, PARAMETER ::   np_MET = 3         ! metric term
   INTEGER, PARAMETER ::   np_CRV = 4         ! relative + planetary (total vorticity)
   INTEGER, PARAMETER ::   np_CME = 5         ! Coriolis + metric term
   
   REAL(wp) ::   r1_4  = 0.250_wp         ! =1/4
   REAL(wp) ::   r1_8  = 0.125_wp         ! =1/8
   REAL(wp) ::   r1_12 = 1._wp / 12._wp   ! 1/12
   
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
!! NEMO/OPA 3.7 , NEMO Consortium (2016)
!! $Id: dynvor.F90 7753 2017-03-03 11:46:59Z mocavero $
!! Software governed by the CeCILL licence     (NEMOGCM/NEMO_CeCILL.txt)
!!----------------------------------------------------------------------
CONTAINS

   SUBROUTINE dyn_vor( kt )
!!----------------------------------------------------------------------
!!
!! ** Purpose :   compute the lateral ocean tracer physics.
!!
!! ** Action : - Update (ua,va) with the now vorticity term trend
!!             - save the trends in (ztrdu,ztrdv) in 2 parts (relative
!!               and planetary vorticity trends) and send them to trd_dyn
!!               for futher diagnostics (l_trddyn=T)
!!----------------------------------------------------------------------
      INTEGER, INTENT( in ) ::   kt   ! ocean time-step index
!
      REAL(wp), POINTER, DIMENSION(:,:,:) ::  ztrdu, ztrdv
!!----------------------------------------------------------------------
!
      IF( nn_timing == 1 )  CALL timing_start('dyn_vor')
!
      IF( l_trddyn )   CALL wrk_alloc( jpi,jpj,jpk, ztrdu, ztrdv )
!
      SELECT CASE ( nvor_scheme )               !==  vorticity trend added to the general trend  ==!
!
      CASE ( np_ENE )                                 !* energy conserving scheme
         IF( l_trddyn ) THEN                                ! trend diagnostics: split the trend in two
            ztrdu(:,:,:) = ua(:,:,:)
            ztrdv(:,:,:) = va(:,:,:)
            CALL vor_ene( kt, nrvm, un , vn , ua, va )                    ! relative vorticity or metric trend
            ztrdu(:,:,:) = ua(:,:,:) - ztrdu(:,:,:)
            ztrdv(:,:,:) = va(:,:,:) - ztrdv(:,:,:)
            CALL trd_dyn( ztrdu, ztrdv, jpdyn_rvo, kt )
            ztrdu(:,:,:) = ua(:,:,:)
            ztrdv(:,:,:) = va(:,:,:)
            CALL vor_ene( kt, ncor, un , vn , ua, va )                    ! planetary vorticity trend
            ztrdu(:,:,:) = ua(:,:,:) - ztrdu(:,:,:)
            ztrdv(:,:,:) = va(:,:,:) - ztrdv(:,:,:)
            CALL trd_dyn( ztrdu, ztrdv, jpdyn_pvo, kt )
         ELSE                                               ! total vorticity trend
                             CALL vor_ene( kt, ntot, un , vn , ua, va )   ! total vorticity trend
            IF( ln_stcor )   CALL vor_ene( kt, ncor, usd, vsd, ua, va )   ! add the Stokes-Coriolis trend
         ENDIF
!
      CASE ( np_ENS )                                 !* enstrophy conserving scheme
         IF( l_trddyn ) THEN                                ! trend diagnostics: splitthe trend in two
            ztrdu(:,:,:) = ua(:,:,:)
            ztrdv(:,:,:) = va(:,:,:)
            CALL vor_ens( kt, nrvm, un , vn , ua, va )            ! relative vorticity or metric trend
            ztrdu(:,:,:) = ua(:,:,:) - ztrdu(:,:,:)
            ztrdv(:,:,:) = va(:,:,:) - ztrdv(:,:,:)
            CALL trd_dyn( ztrdu, ztrdv, jpdyn_rvo, kt )
            ztrdu(:,:,:) = ua(:,:,:)
            ztrdv(:,:,:) = va(:,:,:)
            CALL vor_ens( kt, ncor, un , vn , ua, va )            ! planetary vorticity trend
            ztrdu(:,:,:) = ua(:,:,:) - ztrdu(:,:,:)
            ztrdv(:,:,:) = va(:,:,:) - ztrdv(:,:,:)
            CALL trd_dyn( ztrdu, ztrdv, jpdyn_pvo, kt )
         ELSE                                               ! total vorticity trend
                             CALL vor_ens( kt, ntot, un , vn , ua, va )  ! total vorticity trend
            IF( ln_stcor )   CALL vor_ens( kt, ncor, usd, vsd, ua, va )  ! add the Stokes-Coriolis trend
         ENDIF
!
      CASE ( np_MIX )                                 !* mixed ene-ens scheme
         IF( l_trddyn ) THEN                                ! trend diagnostics: split the trend in two
            ztrdu(:,:,:) = ua(:,:,:)
            ztrdv(:,:,:) = va(:,:,:)
            CALL vor_ens( kt, nrvm, un , vn , ua, va )            ! relative vorticity or metric trend (ens)
            ztrdu(:,:,:) = ua(:,:,:) - ztrdu(:,:,:)
            ztrdv(:,:,:) = va(:,:,:) - ztrdv(:,:,:)
            CALL trd_dyn( ztrdu, ztrdv, jpdyn_rvo, kt )
            ztrdu(:,:,:) = ua(:,:,:)
            ztrdv(:,:,:) = va(:,:,:)
            CALL vor_ene( kt, ncor, un , vn , ua, va )            ! planetary vorticity trend (ene)
            ztrdu(:,:,:) = ua(:,:,:) - ztrdu(:,:,:)
            ztrdv(:,:,:) = va(:,:,:) - ztrdv(:,:,:)
            CALL trd_dyn( ztrdu, ztrdv, jpdyn_pvo, kt )
         ELSE                                               ! total vorticity trend
                             CALL vor_ens( kt, nrvm, un , vn , ua, va )   ! relative vorticity or metric trend (ens)
                             CALL vor_ene( kt, ncor, un , vn , ua, va )   ! planetary vorticity trend (ene)
            IF( ln_stcor )   CALL vor_ene( kt, ncor, usd, vsd, ua, va )   ! add the Stokes-Coriolis trend
        ENDIF
!
      CASE ( np_EEN )                                 !* energy and enstrophy conserving scheme
         IF( l_trddyn ) THEN                                ! trend diagnostics: split the trend in two
            ztrdu(:,:,:) = ua(:,:,:)
            ztrdv(:,:,:) = va(:,:,:)
            CALL vor_een( kt, nrvm, un , vn , ua, va )            ! relative vorticity or metric trend
            ztrdu(:,:,:) = ua(:,:,:) - ztrdu(:,:,:)
            ztrdv(:,:,:) = va(:,:,:) - ztrdv(:,:,:)
            CALL trd_dyn( ztrdu, ztrdv, jpdyn_rvo, kt )
            ztrdu(:,:,:) = ua(:,:,:)
            ztrdv(:,:,:) = va(:,:,:)
            CALL vor_een( kt, ncor, un , vn , ua, va )            ! planetary vorticity trend
            ztrdu(:,:,:) = ua(:,:,:) - ztrdu(:,:,:)
            ztrdv(:,:,:) = va(:,:,:) - ztrdv(:,:,:)
            CALL trd_dyn( ztrdu, ztrdv, jpdyn_pvo, kt )
         ELSE                                               ! total vorticity trend
                             CALL vor_een( kt, ntot, un , vn , ua, va )   ! total vorticity trend
            IF( ln_stcor )   CALL vor_ene( kt, ncor, usd, vsd, ua, va )   ! add the Stokes-Coriolis trend
         ENDIF
!
      END SELECT
!
!                       ! print sum trends (used for debugging)
      IF(ln_ctl) CALL prt_ctl( tab3d_1=ua, clinfo1=' vor  - Ua: ', mask1=umask,               &
         &                     tab3d_2=va, clinfo2=       ' Va: ', mask2=vmask, clinfo3='dyn' )
!
      IF( l_trddyn )   CALL wrk_dealloc( jpi,jpj,jpk, ztrdu, ztrdv )
!
      IF( nn_timing == 1 )  CALL timing_stop('dyn_vor')
!
   END SUBROUTINE dyn_vor


   SUBROUTINE vor_ene( kt, kvor, pun, pvn, pua, pva )
!!----------------------------------------------------------------------
!!                  ***  ROUTINE vor_ene  ***
!!
!! ** Purpose :   Compute the now total vorticity trend and add it to
!!      the general trend of the momentum equation.
!!
!! ** Method  :   Trend evaluated using now fields (centered in time)
!!       and the Sadourny (1975) flux form formulation : conserves the
!!       horizontal kinetic energy.
!!         The general trend of momentum is increased due to the vorticity
!!       term which is given by:
!!          voru = 1/e1u  mj-1[ (rvor+f)/e3f  mi(e1v*e3v vn) ]
!!          vorv = 1/e2v  mi-1[ (rvor+f)/e3f  mj(e2u*e3u un) ]
!!       where rvor is the relative vorticity
!!
!! ** Action : - Update (ua,va) with the now vorticity term trend
!!
!! References : Sadourny, r., 1975, j. atmos. sciences, 32, 680-689.
!!----------------------------------------------------------------------
      INTEGER , INTENT(in   )                         ::   kt          ! ocean time-step index
      INTEGER , INTENT(in   )                         ::   kvor        ! =ncor (planetary) ; =ntot (total) ;
!                                                                ! =nrvm (relative vorticity or metric)
      REAL(wp), INTENT(inout), DIMENSION(jpi,jpj,jpk) ::   pun, pvn    ! now velocities
      REAL(wp), INTENT(inout), DIMENSION(jpi,jpj,jpk) ::   pua, pva    ! total v-trend
!
      INTEGER  ::   ji, jj, jk           ! dummy loop indices
      REAL(wp) ::   zx1, zy1, zx2, zy2   ! local scalars
      REAL(wp), POINTER, DIMENSION(:,:) ::   zwx, zwy, zwz   ! 2D workspace
!!----------------------------------------------------------------------
!
      IF( nn_timing == 1 )  CALL timing_start('vor_ene')
!
      CALL wrk_alloc( jpi,jpj,   zwx, zwy, zwz ) 
!
      IF( kt == nit000 ) THEN
         IF(lwp) WRITE(numout,*)
         IF(lwp) WRITE(numout,*) 'dyn:vor_ene : vorticity term: energy conserving scheme'
         IF(lwp) WRITE(numout,*) '~~~~~~~~~~~'
      ENDIF
!
!                                                ! ===============
      DO jk = 1, jpkm1                                 ! Horizontal slab
!                                             ! ===============
!
         SELECT CASE( kvor )                 !==  vorticity considered  ==!
         CASE ( np_COR )                           !* Coriolis (planetary vorticity)
            zwz(:,:) = ff_f(:,:) 
         CASE ( np_RVO )                           !* relative vorticity
            DO jj = 1, jpjm1
               DO ji = 1, jpim1   ! vector opt.
                  zwz(ji,jj) = (  e2v(ji+1,jj  ) * pvn(ji+1,jj  ,jk) - e2v(ji,jj) * pvn(ji,jj,jk)    &
                     &          - e1u(ji  ,jj+1) * pun(ji  ,jj+1,jk) + e1u(ji,jj) * pun(ji,jj,jk)  ) * r1_e1e2f(ji,jj)
               END DO
            END DO
         CASE ( np_MET )                           !* metric term
            DO jj = 1, jpjm1
               DO ji = 1, jpim1   ! vector opt.
                  zwz(ji,jj) = (   ( pvn(ji+1,jj  ,jk) + pvn (ji,jj,jk) ) * ( e2v(ji+1,jj  ) - e2v(ji,jj) )       &
                       &         - ( pun(ji  ,jj+1,jk) + pun (ji,jj,jk) ) * ( e1u(ji  ,jj+1) - e1u(ji,jj) )   )   &
                       &     * 0.5 * r1_e1e2f(ji,jj)
               END DO
            END DO
         CASE ( np_CRV )                           !* Coriolis + relative vorticity
            DO jj = 1, jpjm1
               DO ji = 1, jpim1   ! vector opt.
                  zwz(ji,jj) = ff_f(ji,jj) + (  e2v(ji+1,jj  ) * pvn(ji+1,jj  ,jk) - e2v(ji,jj) * pvn(ji,jj,jk)    &
                     &                      - e1u(ji  ,jj+1) * pun(ji  ,jj+1,jk) + e1u(ji,jj) * pun(ji,jj,jk)  ) &
                     &                   * r1_e1e2f(ji,jj)
               END DO
            END DO
         CASE ( np_CME )                           !* Coriolis + metric
            DO jj = 1, jpjm1
               DO ji = 1, jpim1   ! vector opt.
                  zwz(ji,jj) = ff_f(ji,jj)                                                                        &
                       &     + (   ( pvn(ji+1,jj  ,jk) + pvn (ji,jj,jk) ) * ( e2v(ji+1,jj  ) - e2v(ji,jj) )       &
                       &         - ( pun(ji  ,jj+1,jk) + pun (ji,jj,jk) ) * ( e1u(ji  ,jj+1) - e1u(ji,jj) )   )   &
                       &     * 0.5 * r1_e1e2f(ji,jj)
               END DO
            END DO
         CASE DEFAULT                                             ! error
            CALL ctl_stop('STOP','dyn_vor: wrong value for kvor'  )
         END SELECT
!
         IF( ln_dynvor_msk ) THEN          !==  mask/unmask vorticity ==!
            DO jj = 1, jpjm1
               DO ji = 1, jpim1   ! vector opt.
                  zwz(ji,jj) = zwz(ji,jj) * fmask(ji,jj,jk)
               END DO
            END DO
         ENDIF

         IF( ln_sco ) THEN
            zwz(:,:) = zwz(:,:) / e3f_n(:,:,jk)
            zwx(:,:) = e2u(:,:) * e3u_n(:,:,jk) * pun(:,:,jk)
            zwy(:,:) = e1v(:,:) * e3v_n(:,:,jk) * pvn(:,:,jk)
         ELSE
            zwx(:,:) = e2u(:,:) * pun(:,:,jk)
            zwy(:,:) = e1v(:,:) * pvn(:,:,jk)
         ENDIF
!                                   !==  compute and add the vorticity term trend  =!
         DO jj = 2, jpjm1
            DO ji = 2, jpim1   ! vector opt.
               zy1 = zwy(ji,jj-1) + zwy(ji+1,jj-1)
               zy2 = zwy(ji,jj  ) + zwy(ji+1,jj  )
               zx1 = zwx(ji-1,jj) + zwx(ji-1,jj+1)
               zx2 = zwx(ji  ,jj) + zwx(ji  ,jj+1)
               pua(ji,jj,jk) = pua(ji,jj,jk) + r1_4 * r1_e1u(ji,jj) * ( zwz(ji  ,jj-1) * zy1 + zwz(ji,jj) * zy2 )
               pva(ji,jj,jk) = pva(ji,jj,jk) - r1_4 * r1_e2v(ji,jj) * ( zwz(ji-1,jj  ) * zx1 + zwz(ji,jj) * zx2 ) 
            END DO  
         END DO  
!                                             ! ===============
      END DO                                           !   End of slab
!                                                ! ===============
      CALL wrk_dealloc( jpi, jpj, zwx, zwy, zwz ) 
!
      IF( nn_timing == 1 )  CALL timing_stop('vor_ene')
!
   END SUBROUTINE vor_ene


   SUBROUTINE vor_ens( kt, kvor, pun, pvn, pua, pva )
!!----------------------------------------------------------------------
!!                ***  ROUTINE vor_ens  ***
!!
!! ** Purpose :   Compute the now total vorticity trend and add it to
!!      the general trend of the momentum equation.
!!
!! ** Method  :   Trend evaluated using now fields (centered in time)
!!      and the Sadourny (1975) flux FORM formulation : conserves the
!!      potential enstrophy of a horizontally non-divergent flow. the
!!      trend of the vorticity term is given by:
!!          voru = 1/e1u  mj-1[ (rvor+f)/e3f ]  mj-1[ mi(e1v*e3v vn) ]
!!          vorv = 1/e2v  mi-1[ (rvor+f)/e3f ]  mi-1[ mj(e2u*e3u un) ]
!!      Add this trend to the general momentum trend (ua,va):
!!          (ua,va) = (ua,va) + ( voru , vorv )
!!
!! ** Action : - Update (ua,va) arrays with the now vorticity term trend
!!
!! References : Sadourny, r., 1975, j. atmos. sciences, 32, 680-689.
!!----------------------------------------------------------------------
      INTEGER , INTENT(in   )                         ::   kt          ! ocean time-step index
      INTEGER , INTENT(in   )                         ::   kvor        ! =ncor (planetary) ; =ntot (total) ;
!                                                             ! =nrvm (relative vorticity or metric)
      REAL(wp), INTENT(inout), DIMENSION(jpi,jpj,jpk) ::   pun, pvn    ! now velocities
      REAL(wp), INTENT(inout), DIMENSION(jpi,jpj,jpk) ::   pua, pva    ! total v-trend
!
      INTEGER  ::   ji, jj, jk   ! dummy loop indices
      REAL(wp) ::   zuav, zvau   ! local scalars
      REAL(wp), POINTER, DIMENSION(:,:) ::   zwx, zwy, zwz, zww   ! 2D workspace
!!----------------------------------------------------------------------
!
      IF( nn_timing == 1 )  CALL timing_start('vor_ens')
!
      CALL wrk_alloc( jpi,jpj,   zwx, zwy, zwz ) 
!
      IF( kt == nit000 ) THEN
         IF(lwp) WRITE(numout,*)
         IF(lwp) WRITE(numout,*) 'dyn:vor_ens : vorticity term: enstrophy conserving scheme'
         IF(lwp) WRITE(numout,*) '~~~~~~~~~~~'
      ENDIF
!                                                ! ===============
      DO jk = 1, jpkm1                                 ! Horizontal slab
!                                             ! ===============
!
         SELECT CASE( kvor )                 !==  vorticity considered  ==!
         CASE ( np_COR )                           !* Coriolis (planetary vorticity)
            zwz(:,:) = ff_f(:,:) 
         CASE ( np_RVO )                           !* relative vorticity
            DO jj = 1, jpjm1
               DO ji = 1, jpim1   ! vector opt.
                  zwz(ji,jj) = (  e2v(ji+1,jj  ) * pvn(ji+1,jj  ,jk) - e2v(ji,jj) * pvn(ji,jj,jk)    &
                     &          - e1u(ji  ,jj+1) * pun(ji  ,jj+1,jk) + e1u(ji,jj) * pun(ji,jj,jk)  ) * r1_e1e2f(ji,jj)
               END DO
            END DO
         CASE ( np_MET )                           !* metric term
            DO jj = 1, jpjm1
               DO ji = 1, jpim1   ! vector opt.
                  zwz(ji,jj) = (   ( pvn(ji+1,jj  ,jk) + pvn (ji,jj,jk) ) * ( e2v(ji+1,jj  ) - e2v(ji,jj) )       &
                       &         - ( pun(ji  ,jj+1,jk) + pun (ji,jj,jk) ) * ( e1u(ji  ,jj+1) - e1u(ji,jj) )   )   &
                       &     * 0.5 * r1_e1e2f(ji,jj)
               END DO
            END DO
         CASE ( np_CRV )                           !* Coriolis + relative vorticity
            DO jj = 1, jpjm1
               DO ji = 1, jpim1   ! vector opt.
                  zwz(ji,jj) = ff_f(ji,jj) + (  e2v(ji+1,jj  ) * pvn(ji+1,jj  ,jk) - e2v(ji,jj) * pvn(ji,jj,jk)    &
                     &                      - e1u(ji  ,jj+1) * pun(ji  ,jj+1,jk) + e1u(ji,jj) * pun(ji,jj,jk)  ) &
                     &                   * r1_e1e2f(ji,jj)
               END DO
            END DO
         CASE ( np_CME )                           !* Coriolis + metric
            DO jj = 1, jpjm1
               DO ji = 1, jpim1   ! vector opt.
                  zwz(ji,jj) = ff_f(ji,jj)                                                                       &
                       &     + (   ( pvn(ji+1,jj  ,jk) + pvn (ji,jj,jk) ) * ( e2v(ji+1,jj  ) - e2v(ji,jj) )       &
                       &         - ( pun(ji  ,jj+1,jk) + pun (ji,jj,jk) ) * ( e1u(ji  ,jj+1) - e1u(ji,jj) )   )   &
                       &     * 0.5 * r1_e1e2f(ji,jj)
               END DO
            END DO
         CASE DEFAULT                                             ! error
            CALL ctl_stop('STOP','dyn_vor: wrong value for kvor'  )
         END SELECT
!
         IF( ln_dynvor_msk ) THEN           !==  mask/unmask vorticity ==!
            DO jj = 1, jpjm1
               DO ji = 1, jpim1   ! vector opt.
                  zwz(ji,jj) = zwz(ji,jj) * fmask(ji,jj,jk)
               END DO
            END DO
         ENDIF
!
         IF( ln_sco ) THEN                   !==  horizontal fluxes  ==!
            zwz(:,:) = zwz(:,:) / e3f_n(:,:,jk)
            zwx(:,:) = e2u(:,:) * e3u_n(:,:,jk) * pun(:,:,jk)
            zwy(:,:) = e1v(:,:) * e3v_n(:,:,jk) * pvn(:,:,jk)
         ELSE
            zwx(:,:) = e2u(:,:) * pun(:,:,jk)
            zwy(:,:) = e1v(:,:) * pvn(:,:,jk)
         ENDIF
!                                   !==  compute and add the vorticity term trend  =!
         DO jj = 2, jpjm1
            DO ji = 2, jpim1   ! vector opt.
               zuav = r1_8 * r1_e1u(ji,jj) * (  zwy(ji  ,jj-1) + zwy(ji+1,jj-1)  &
                  &                           + zwy(ji  ,jj  ) + zwy(ji+1,jj  )  )
               zvau =-r1_8 * r1_e2v(ji,jj) * (  zwx(ji-1,jj  ) + zwx(ji-1,jj+1)  &
                  &                           + zwx(ji  ,jj  ) + zwx(ji  ,jj+1)  )
               pua(ji,jj,jk) = pua(ji,jj,jk) + zuav * ( zwz(ji  ,jj-1) + zwz(ji,jj) )
               pva(ji,jj,jk) = pva(ji,jj,jk) + zvau * ( zwz(ji-1,jj  ) + zwz(ji,jj) )
            END DO  
         END DO  
!                                             ! ===============
      END DO                                           !   End of slab
!                                                ! ===============
      CALL wrk_dealloc( jpi, jpj, zwx, zwy, zwz ) 
!
      IF( nn_timing == 1 )  CALL timing_stop('vor_ens')
!
   END SUBROUTINE vor_ens


   SUBROUTINE vor_een( kt, kvor, pun, pvn, pua, pva )
!!----------------------------------------------------------------------
!!                ***  ROUTINE vor_een  ***
!!
!! ** Purpose :   Compute the now total vorticity trend and add it to
!!      the general trend of the momentum equation.
!!
!! ** Method  :   Trend evaluated using now fields (centered in time)
!!      and the Arakawa and Lamb (1980) flux form formulation : conserves
!!      both the horizontal kinetic energy and the potential enstrophy
!!      when horizontal divergence is zero (see the NEMO documentation)
!!      Add this trend to the general momentum trend (ua,va).
!!
!! ** Action : - Update (ua,va) with the now vorticity term trend
!!
!! References : Arakawa and Lamb 1980, Mon. Wea. Rev., 109, 18-36
!!----------------------------------------------------------------------
      INTEGER , INTENT(in   )                         ::   kt          ! ocean time-step index
      INTEGER , INTENT(in   )                         ::   kvor        ! =ncor (planetary) ; =ntot (total) ;
!                                                             ! =nrvm (relative vorticity or metric)
      REAL(wp), INTENT(inout), DIMENSION(jpi,jpj,jpk) ::   pun, pvn    ! now velocities
      REAL(wp), INTENT(inout), DIMENSION(jpi,jpj,jpk) ::   pua, pva    ! total v-trend
!
      INTEGER  ::   ji, jj, jk   ! dummy loop indices
      INTEGER  ::   ierr         ! local integer
      REAL(wp) ::   zua, zva     ! local scalars
      REAL(wp) ::   zmsk, ze3    ! local scalars
!
      REAL(wp), POINTER, DIMENSION(:,:)   :: zwx, zwy, zwz, z1_e3f
      REAL(wp), POINTER, DIMENSION(:,:)   :: ztnw, ztne, ztsw, ztse
!!----------------------------------------------------------------------
!
      IF( nn_timing == 1 )  CALL timing_start('vor_een')
!
      CALL wrk_alloc( jpi,jpj,   zwx , zwy , zwz , z1_e3f ) 
      CALL wrk_alloc( jpi,jpj,   ztnw, ztne, ztsw, ztse   ) 
!
      IF( kt == nit000 ) THEN
         IF(lwp) WRITE(numout,*)
         IF(lwp) WRITE(numout,*) 'dyn:vor_een : vorticity term: energy and enstrophy conserving scheme'
         IF(lwp) WRITE(numout,*) '~~~~~~~~~~~'
      ENDIF
!
!                                                ! ===============
      DO jk = 1, jpkm1                                 ! Horizontal slab
!                                             ! ===============
!
         SELECT CASE( nn_een_e3f )           ! == reciprocal of e3 at F-point
         CASE ( 0 )                                   ! original formulation  (masked averaging of e3t divided by 4)
            DO jj = 1, jpjm1
               DO ji = 1, jpim1   ! vector opt.
                  ze3  = (  e3t_n(ji,jj+1,jk)*tmask(ji,jj+1,jk) + e3t_n(ji+1,jj+1,jk)*tmask(ji+1,jj+1,jk)   &
                     &    + e3t_n(ji,jj  ,jk)*tmask(ji,jj  ,jk) + e3t_n(ji+1,jj  ,jk)*tmask(ji+1,jj  ,jk)  )
                  IF( ze3 /= 0._wp ) THEN   ;   z1_e3f(ji,jj) = 4._wp / ze3
                  ELSE                      ;   z1_e3f(ji,jj) = 0._wp
                  ENDIF
               END DO
            END DO
         CASE ( 1 )                                   ! new formulation  (masked averaging of e3t divided by the sum of mask)
            DO jj = 1, jpjm1
               DO ji = 1, jpim1   ! vector opt.
                  ze3  = (  e3t_n(ji,jj+1,jk)*tmask(ji,jj+1,jk) + e3t_n(ji+1,jj+1,jk)*tmask(ji+1,jj+1,jk)   &
                     &    + e3t_n(ji,jj  ,jk)*tmask(ji,jj  ,jk) + e3t_n(ji+1,jj  ,jk)*tmask(ji+1,jj  ,jk)  )
                  zmsk = (                    tmask(ji,jj+1,jk) +                     tmask(ji+1,jj+1,jk)   &
                     &                      + tmask(ji,jj  ,jk) +                     tmask(ji+1,jj  ,jk)  )
                  IF( ze3 /= 0._wp ) THEN   ;   z1_e3f(ji,jj) = zmsk / ze3
                  ELSE                      ;   z1_e3f(ji,jj) = 0._wp
                  ENDIF
               END DO
            END DO
         END SELECT
!
         SELECT CASE( kvor )                 !==  vorticity considered  ==!
         CASE ( np_COR )                           !* Coriolis (planetary vorticity)
            DO jj = 1, jpjm1
               DO ji = 1, jpim1   ! vector opt.
                  zwz(ji,jj) = ff_f(ji,jj) * z1_e3f(ji,jj)
               END DO
            END DO
         CASE ( np_RVO )                           !* relative vorticity
            DO jj = 1, jpjm1
               DO ji = 1, jpim1   ! vector opt.
                  zwz(ji,jj) = (  e2v(ji+1,jj  ) * pvn(ji+1,jj  ,jk) - e2v(ji,jj) * pvn(ji,jj,jk)    &
                     &          - e1u(ji  ,jj+1) * pun(ji  ,jj+1,jk) + e1u(ji,jj) * pun(ji,jj,jk)  ) &
                     &       * r1_e1e2f(ji,jj) * z1_e3f(ji,jj)
               END DO
            END DO
         CASE ( np_MET )                           !* metric term
            DO jj = 1, jpjm1
               DO ji = 1, jpim1   ! vector opt.
                  zwz(ji,jj) = (   ( pvn(ji+1,jj  ,jk) + pvn (ji,jj,jk) ) * ( e2v(ji+1,jj  ) - e2v(ji,jj) )       &
                       &         - ( pun(ji  ,jj+1,jk) + pun (ji,jj,jk) ) * ( e1u(ji  ,jj+1) - e1u(ji,jj) )   )   &
                       &     * 0.5 * r1_e1e2f(ji,jj) * z1_e3f(ji,jj)
               END DO
            END DO
         CASE ( np_CRV )                           !* Coriolis + relative vorticity
            DO jj = 1, jpjm1
               DO ji = 1, jpim1   ! vector opt.
                  zwz(ji,jj) = (  ff_f(ji,jj) + (  e2v(ji+1,jj  ) * pvn(ji+1,jj  ,jk) - e2v(ji,jj) * pvn(ji,jj,jk)    &
                     &                           - e1u(ji  ,jj+1) * pun(ji  ,jj+1,jk) + e1u(ji,jj) * pun(ji,jj,jk)  ) &
                     &                      * r1_e1e2f(ji,jj)    ) * z1_e3f(ji,jj)
               END DO
            END DO
         CASE ( np_CME )                           !* Coriolis + metric
            DO jj = 1, jpjm1
               DO ji = 1, jpim1   ! vector opt.
                  zwz(ji,jj) = (  ff_f(ji,jj)                                                                        &
                       &        + (   ( pvn(ji+1,jj  ,jk) + pvn (ji,jj,jk) ) * ( e2v(ji+1,jj  ) - e2v(ji,jj) )       &
                       &            - ( pun(ji  ,jj+1,jk) + pun (ji,jj,jk) ) * ( e1u(ji  ,jj+1) - e1u(ji,jj) )   )   &
                       &        * 0.5 * r1_e1e2f(ji,jj)   ) * z1_e3f(ji,jj)
               END DO
            END DO
         CASE DEFAULT                                             ! error
            CALL ctl_stop('STOP','dyn_vor: wrong value for kvor'  )
         END SELECT
!
         IF( ln_dynvor_msk ) THEN          !==  mask/unmask vorticity ==!
            DO jj = 1, jpjm1
               DO ji = 1, jpim1   ! vector opt.
                  zwz(ji,jj) = zwz(ji,jj) * fmask(ji,jj,jk)
               END DO
            END DO
         ENDIF
!
         CALL lbc_lnk( zwz, 'F', 1. )
!
!                                   !==  horizontal fluxes  ==!
         zwx(:,:) = e2u(:,:) * e3u_n(:,:,jk) * pun(:,:,jk)
         zwy(:,:) = e1v(:,:) * e3v_n(:,:,jk) * pvn(:,:,jk)

!                                   !==  compute and add the vorticity term trend  =!
         jj = 2
         ztne(1,:) = 0   ;   ztnw(1,:) = 0   ;   ztse(1,:) = 0   ;   ztsw(1,:) = 0
         DO ji = 2, jpi          ! split in 2 parts due to vector opt.
               ztne(ji,jj) = zwz(ji-1,jj  ) + zwz(ji  ,jj  ) + zwz(ji  ,jj-1)
               ztnw(ji,jj) = zwz(ji-1,jj-1) + zwz(ji-1,jj  ) + zwz(ji  ,jj  )
               ztse(ji,jj) = zwz(ji  ,jj  ) + zwz(ji  ,jj-1) + zwz(ji-1,jj-1)
               ztsw(ji,jj) = zwz(ji  ,jj-1) + zwz(ji-1,jj-1) + zwz(ji-1,jj  )
         END DO
         DO jj = 3, jpj
            DO ji = 2, jpi   ! vector opt. ok because we start at jj = 3
               ztne(ji,jj) = zwz(ji-1,jj  ) + zwz(ji  ,jj  ) + zwz(ji  ,jj-1)
               ztnw(ji,jj) = zwz(ji-1,jj-1) + zwz(ji-1,jj  ) + zwz(ji  ,jj  )
               ztse(ji,jj) = zwz(ji  ,jj  ) + zwz(ji  ,jj-1) + zwz(ji-1,jj-1)
               ztsw(ji,jj) = zwz(ji  ,jj-1) + zwz(ji-1,jj-1) + zwz(ji-1,jj  )
            END DO
         END DO
         DO jj = 2, jpjm1
            DO ji = 2, jpim1   ! vector opt.
               zua = + r1_12 * r1_e1u(ji,jj) * (  ztne(ji,jj  ) * zwy(ji  ,jj  ) + ztnw(ji+1,jj) * zwy(ji+1,jj  )   &
                  &                             + ztse(ji,jj  ) * zwy(ji  ,jj-1) + ztsw(ji+1,jj) * zwy(ji+1,jj-1) )
               zva = - r1_12 * r1_e2v(ji,jj) * (  ztsw(ji,jj+1) * zwx(ji-1,jj+1) + ztse(ji,jj+1) * zwx(ji  ,jj+1)   &
                  &                             + ztnw(ji,jj  ) * zwx(ji-1,jj  ) + ztne(ji,jj  ) * zwx(ji  ,jj  ) )
               pua(ji,jj,jk) = pua(ji,jj,jk) + zua
               pva(ji,jj,jk) = pva(ji,jj,jk) + zva
            END DO  
         END DO  
!                                             ! ===============
      END DO                                           !   End of slab
!                                                ! ===============
!
      CALL wrk_dealloc( jpi,jpj,   zwx , zwy , zwz , z1_e3f ) 
      CALL wrk_dealloc( jpi,jpj,   ztnw, ztne, ztsw, ztse   ) 
!
      IF( nn_timing == 1 )  CALL timing_stop('vor_een')
!
   END SUBROUTINE vor_een


   SUBROUTINE dyn_vor_init
!!---------------------------------------------------------------------
!!                  ***  ROUTINE dyn_vor_init  ***
!!
!! ** Purpose :   Control the consistency between cpp options for
!!              tracer advection schemes
!!----------------------------------------------------------------------
      INTEGER ::   ioptio          ! local integer
      INTEGER ::   ji, jj, jk      ! dummy loop indices
      INTEGER ::   ios             ! Local integer output status for namelist read
!!
      NAMELIST/namdyn_vor/ ln_dynvor_ens, ln_dynvor_ene, ln_dynvor_mix, ln_dynvor_een, nn_een_e3f, ln_dynvor_msk
!!----------------------------------------------------------------------

      REWIND( numnam_ref )              ! Namelist namdyn_vor in reference namelist : Vorticity scheme options
      READ  ( numnam_ref, namdyn_vor, IOSTAT = ios, ERR = 901)
901   IF( ios /= 0 ) CALL ctl_nam ( ios , 'namdyn_vor in reference namelist', lwp )

      REWIND( numnam_cfg )              ! Namelist namdyn_vor in configuration namelist : Vorticity scheme options
      READ  ( numnam_cfg, namdyn_vor, IOSTAT = ios, ERR = 902 )
902   IF( ios /= 0 ) CALL ctl_nam ( ios , 'namdyn_vor in configuration namelist', lwp )
      IF(lwm) WRITE ( numond, namdyn_vor )

      IF(lwp) THEN                    ! Namelist print
         WRITE(numout,*)
         WRITE(numout,*) 'dyn_vor_init : vorticity term : read namelist and control the consistency'
         WRITE(numout,*) '~~~~~~~~~~~~'
         WRITE(numout,*) '   Namelist namdyn_vor : choice of the vorticity term scheme'
         WRITE(numout,*) '      energy    conserving scheme                    ln_dynvor_ene = ', ln_dynvor_ene
         WRITE(numout,*) '      enstrophy conserving scheme                    ln_dynvor_ens = ', ln_dynvor_ens
         WRITE(numout,*) '      mixed enstrophy/energy conserving scheme       ln_dynvor_mix = ', ln_dynvor_mix
         WRITE(numout,*) '      enstrophy and energy conserving scheme         ln_dynvor_een = ', ln_dynvor_een
         WRITE(numout,*) '         e3f = averaging /4 (=0) or /sum(tmask) (=1)    nn_een_e3f = ', nn_een_e3f
         WRITE(numout,*) '      masked (=T) or unmasked(=F) vorticity          ln_dynvor_msk = ', ln_dynvor_msk
      ENDIF

!!gm  this should be removed when choosing a unique strategy for fmask at the coast
! If energy, enstrophy or mixed advection of momentum in vector form change the value for masks
! at angles with three ocean points and one land point
      IF(lwp) WRITE(numout,*)
      IF(lwp) WRITE(numout,*) '      change fmask value in the angles (T)           ln_vorlat = ', ln_vorlat
      IF( ln_vorlat .AND. ( ln_dynvor_ene .OR. ln_dynvor_ens .OR. ln_dynvor_mix ) ) THEN
         DO jk = 1, jpk
            DO jj = 2, jpjm1
               DO ji = 2, jpim1
                  IF( tmask(ji,jj,jk)+tmask(ji+1,jj,jk)+tmask(ji,jj+1,jk)+tmask(ji+1,jj+1,jk) == 3._wp ) &
                      fmask(ji,jj,jk) = 1._wp
               END DO
            END DO
         END DO
!
          CALL lbc_lnk( fmask, 'F', 1._wp )      ! Lateral boundary conditions on fmask
!
      ENDIF
!!gm end

      ioptio = 0                     ! type of scheme for vorticity (set nvor_scheme)
      IF( ln_dynvor_ene ) THEN   ;   ioptio = ioptio + 1   ;    nvor_scheme = np_ENE   ;   ENDIF
      IF( ln_dynvor_ens ) THEN   ;   ioptio = ioptio + 1   ;    nvor_scheme = np_ENS   ;   ENDIF
      IF( ln_dynvor_mix ) THEN   ;   ioptio = ioptio + 1   ;    nvor_scheme = np_MIX   ;   ENDIF
      IF( ln_dynvor_een ) THEN   ;   ioptio = ioptio + 1   ;    nvor_scheme = np_EEN   ;   ENDIF
!
      IF( ioptio /= 1 ) CALL ctl_stop( ' use ONE and ONLY one vorticity scheme' )
!
      IF(lwp) WRITE(numout,*)        ! type of calculated vorticity (set ncor, nrvm, ntot)
      ncor = np_COR
      IF( ln_dynadv_vec ) THEN     
         IF(lwp) WRITE(numout,*) '      ===>>   Vector form advection : vorticity = Coriolis + relative vorticity'
         nrvm = np_RVO        ! relative vorticity
         ntot = np_CRV        ! relative + planetary vorticity
      ELSE                        
         IF(lwp) WRITE(numout,*) '      ===>>   Flux form advection   : vorticity = Coriolis + metric term'
         nrvm = np_MET        ! metric term
         ntot = np_CME        ! Coriolis + metric term
      ENDIF
      
      IF(lwp) THEN                   ! Print the choice
         WRITE(numout,*)
         IF( nvor_scheme ==  np_ENE )   WRITE(numout,*) '      ===>>   energy conserving scheme'
         IF( nvor_scheme ==  np_ENS )   WRITE(numout,*) '      ===>>   enstrophy conserving scheme'
         IF( nvor_scheme ==  np_MIX )   WRITE(numout,*) '      ===>>   mixed enstrophy/energy conserving scheme'
         IF( nvor_scheme ==  np_EEN )   WRITE(numout,*) '      ===>>   energy and enstrophy conserving scheme'
      ENDIF
!
   END SUBROUTINE dyn_vor_init

!!==============================================================================
END MODULE dynvor
