MODULE istate
!!======================================================================
!!                     ***  MODULE  istate  ***
!! Ocean state   :  initial state setting
!!=====================================================================
!! History :  OPA  !  1989-12  (P. Andrich)  Original code
!!            5.0  !  1991-11  (G. Madec)  rewritting
!!            6.0  !  1996-01  (G. Madec)  terrain following coordinates
!!            8.0  !  2001-09  (M. Levy, M. Ben Jelloul)  istate_eel
!!            8.0  !  2001-09  (M. Levy, M. Ben Jelloul)  istate_uvg
!!   NEMO     1.0  !  2003-08  (G. Madec, C. Talandier)  F90: Free form, modules + EEL R5
!!             -   !  2004-05  (A. Koch-Larrouy)  istate_gyre
!!            2.0  !  2006-07  (S. Masson)  distributed restart using iom
!!            3.3  !  2010-10  (C. Ethe) merge TRC-TRA
!!            3.4  !  2011-04  (G. Madec) Merge of dtatem and dtasal & suppression of tb,tn/sb,sn
!!            3.7  !  2016-04  (S. Flavoni) introduce user defined initial state
!!----------------------------------------------------------------------

!!----------------------------------------------------------------------
!!   istate_init   : initial state setting
!!   istate_uvg    : initial velocity in geostropic balance
!!----------------------------------------------------------------------
   USE oce            ! ocean dynamics and active tracers
   USE dom_oce        ! ocean space and time domain
   USE daymod         ! calendar
   USE divhor         ! horizontal divergence            (div_hor routine)
   USE dtatsd         ! data temperature and salinity   (dta_tsd routine)
   USE dtauvd         ! data: U & V current             (dta_uvd routine)
   USE domvvl          ! varying vertical mesh
   USE iscplrst        ! ice sheet coupling
   USE wet_dry         ! wetting and drying (needed for wad_istate)
   USE usrdef_istate   ! User defined initial state
!
   USE in_out_manager  ! I/O manager
   USE iom             ! I/O library
   USE lib_mpp         ! MPP library
   USE restart         ! restart
   USE wrk_nemo        ! Memory allocation
   USE timing          ! Timing

   IMPLICIT NONE
   PRIVATE

   PUBLIC   istate_init   ! routine called by step.F90

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
!! $Id: istate.F90 7753 2017-03-03 11:46:59Z mocavero $
!! Software governed by the CeCILL licence     (NEMOGCM/NEMO_CeCILL.txt)
!!----------------------------------------------------------------------
CONTAINS

   SUBROUTINE istate_init
!!----------------------------------------------------------------------
!!                   ***  ROUTINE istate_init  ***
!!
!! ** Purpose :   Initialization of the dynamics and tracer fields.
!!----------------------------------------------------------------------
      INTEGER ::   ji, jj, jk   ! dummy loop indices
      REAL(wp), POINTER, DIMENSION(:,:,:,:) ::   zuvd    ! U & V data workspace
!!----------------------------------------------------------------------
!
      IF( nn_timing == 1 )   CALL timing_start('istate_init')
!
      IF(lwp) WRITE(numout,*)
      IF(lwp) WRITE(numout,*) 'istate_init : Initialization of the dynamics and tracers'
      IF(lwp) WRITE(numout,*) '~~~~~~~~~~~'

!!gm  Why not include in the first call of dta_tsd ?
!!gm  probably associated with the use of internal damping...
                     CALL dta_tsd_init        ! Initialisation of T & S input data
!!gm to be moved in usrdef of C1D case
!      IF( lk_c1d )   CALL dta_uvd_init        ! Initialization of U & V input data
!!gm

      rhd  (:,:,:  ) = 0._wp   ;   rhop (:,:,:  ) = 0._wp      ! set one for all to 0 at level jpk
      rn2b (:,:,:  ) = 0._wp   ;   rn2  (:,:,:  ) = 0._wp      ! set one for all to 0 at levels 1 and jpk
      tsa  (:,:,:,:) = 0._wp                                   ! set one for all to 0 at level jpk
      rab_b(:,:,:,:) = 0._wp   ;   rab_n(:,:,:,:) = 0._wp      ! set one for all to 0 at level jpk

      IF( ln_rstart ) THEN                    ! Restart from a file
!                                    ! -------------------
         CALL rst_read                        ! Read the restart file
         IF (ln_iscpl)       CALL iscpl_stp   ! extrapolate restart to wet and dry
         CALL day_init                        ! model calendar (using both namelist and restart infos)
!
      ELSE                                    ! Start from rest
!                                    ! ---------------
         numror = 0                           ! define numror = 0 -> no restart file to read
         neuler = 0                           ! Set time-step indicator at nit000 (euler forward)
         CALL day_init                        ! model calendar (using both namelist and restart infos)
!                                    ! Initialization of ocean to zero
!
         IF( ln_tsd_init ) THEN               
            CALL dta_tsd( nit000, tsb )       ! read 3D T and S data at nit000
!
            sshb(:,:)   = 0._wp               ! set the ocean at rest
            ub  (:,:,:) = 0._wp
            vb  (:,:,:) = 0._wp  
!
         ELSE                                 ! user defined initial T and S
            CALL usr_def_istate( gdept_b, tmask, tsb, ub, vb, sshb  )         
         ENDIF
         tsn  (:,:,:,:) = tsb (:,:,:,:)       ! set now values from to before ones
         sshn (:,:)     = sshb(:,:)   
         un   (:,:,:)   = ub  (:,:,:)
         vn   (:,:,:)   = vb  (:,:,:)
         hdivn(:,:,jpk) = 0._wp               ! bottom divergence set one for 0 to zero at jpk level
         CALL div_hor( 0 )                    ! compute interior hdivn value
!!gm                                    hdivn(:,:,:) = 0._wp

!!gm POTENTIAL BUG :
!!gm  ISSUE :  if sshb /= 0  then, in non linear free surface, the e3._n, e3._b should be recomputed
!!             as well as gdept and gdepw....   !!!!!
!!      ===>>>>   probably a call to domvvl initialisation here....


!
!!gm to be moved in usrdef of C1D case
!         IF ( ln_uvd_init .AND. lk_c1d ) THEN ! read 3D U and V data at nit000
!            CALL wrk_alloc( jpi,jpj,jpk,2,   zuvd )
!            CALL dta_uvd( nit000, zuvd )
!            ub(:,:,:) = zuvd(:,:,:,1) ;  un(:,:,:) = ub(:,:,:)
!            vb(:,:,:) = zuvd(:,:,:,2) ;  vn(:,:,:) = vb(:,:,:)
!            CALL wrk_dealloc( jpi,jpj,jpk,2,   zuvd )
!         ENDIF
!
!!gm This is to be changed !!!!
!         ! - ML - sshn could be modified by istate_eel, so that initialization of e3t_b is done here
!         IF( .NOT.ln_linssh ) THEN
!            DO jk = 1, jpk
!               e3t_b(:,:,jk) = e3t_n(:,:,jk)
!            END DO
!         ENDIF
!!gm
!
      ENDIF 
!
! Initialize "now" and "before" barotropic velocities:
! Do it whatever the free surface method, these arrays being eventually used
!
      un_b(:,:) = 0._wp   ;   vn_b(:,:) = 0._wp
      ub_b(:,:) = 0._wp   ;   vb_b(:,:) = 0._wp
!
!!gm  the use of umsak & vmask is not necessary below as un, vn, ub, vb are always masked
      DO jk = 1, jpkm1
         DO jj = 1, jpj
            DO ji = 1, jpi
               un_b(ji,jj) = un_b(ji,jj) + e3u_n(ji,jj,jk) * un(ji,jj,jk) * umask(ji,jj,jk)
               vn_b(ji,jj) = vn_b(ji,jj) + e3v_n(ji,jj,jk) * vn(ji,jj,jk) * vmask(ji,jj,jk)
!
               ub_b(ji,jj) = ub_b(ji,jj) + e3u_b(ji,jj,jk) * ub(ji,jj,jk) * umask(ji,jj,jk)
               vb_b(ji,jj) = vb_b(ji,jj) + e3v_b(ji,jj,jk) * vb(ji,jj,jk) * vmask(ji,jj,jk)
            END DO
         END DO
      END DO
!
      un_b(:,:) = un_b(:,:) * r1_hu_n(:,:)
      vn_b(:,:) = vn_b(:,:) * r1_hv_n(:,:)
!
      ub_b(:,:) = ub_b(:,:) * r1_hu_b(:,:)
      vb_b(:,:) = vb_b(:,:) * r1_hv_b(:,:)
!
      IF( nn_timing == 1 )   CALL timing_stop('istate_init')
!
   END SUBROUTINE istate_init

!!======================================================================
END MODULE istate
