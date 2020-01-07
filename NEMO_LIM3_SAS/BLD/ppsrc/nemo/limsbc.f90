MODULE limsbc
!!======================================================================
!!                       ***  MODULE limsbc   ***
!!           computation of the flux at the sea ice/ocean interface
!!======================================================================
!! History :   -   ! 2006-07 (M. Vancoppelle)  LIM3 original code
!!            3.0  ! 2008-03 (C. Tallandier)  surface module
!!             -   ! 2008-04 (C. Tallandier)  split in 2 + new ice-ocean coupling
!!            3.3  ! 2010-05 (G. Madec) decrease ocean & ice reference salinities in the Baltic sea
!!                 !                  + simplification of the ice-ocean stress calculation
!!            3.4  ! 2011-02 (G. Madec) dynamical allocation
!!             -   ! 2012    (D. Iovino) salt flux change
!!             -   ! 2012-05 (C. Rousset) add penetration solar flux
!!            3.5  ! 2012-10 (A. Coward, G. Madec) salt fluxes ; ice+snow mass
!!----------------------------------------------------------------------

!!----------------------------------------------------------------------
!!   'key_lim3'                                    LIM 3.0 sea-ice model
!!----------------------------------------------------------------------
!!   lim_sbc_alloc : allocate the limsbc arrays
!!   lim_sbc_init  : initialisation
!!   lim_sbc_flx   : updates mass, heat and salt fluxes at the ocean surface
!!   lim_sbc_tau   : update i- and j-stresses, and its modulus at the ocean surface
!!----------------------------------------------------------------------
   USE par_oce        ! ocean parameters
   USE oce     , ONLY : sshn, sshb, snwice_mass, snwice_mass_b, snwice_fmass
   USE phycst         ! physical constants
   USE dom_oce        ! ocean domain
   USE ice            ! LIM sea-ice variables
   USE sbc_ice        ! Surface boundary condition: sea-ice fields
   USE sbc_oce        ! Surface boundary condition: ocean fields
   USE sbccpl         ! Surface boundary condition: coupled interface
   USE albedo         ! albedo parameters
   USE traqsr         ! add penetration of solar flux in the calculation of heat budget
   USE domvvl         ! Variable volume
   USE limctl         !
   USE limcons        !
   USE bdy_oce  , ONLY: ln_bdy
!
   USE in_out_manager ! I/O manager
   USE iom            ! xIO server
   USE lbclnk         ! ocean lateral boundary condition - MPP exchanges
   USE lib_mpp        ! MPP library
   USE wrk_nemo       ! work arrays
   USE lib_fortran    ! Fortran utilities (allows no signed zero when 'key_nosignedzero' defined)

   IMPLICIT NONE
   PRIVATE

   PUBLIC   lim_sbc_init   ! called by sbc_lim_init
   PUBLIC   lim_sbc_flx    ! called by sbc_ice_lim
   PUBLIC   lim_sbc_tau    ! called by sbc_ice_lim

   REAL(wp), ALLOCATABLE, SAVE, DIMENSION(:,:) ::   utau_oce, vtau_oce   ! air-ocean surface i- & j-stress     [N/m2]
   REAL(wp), ALLOCATABLE, SAVE, DIMENSION(:,:) ::   tmod_io              ! modulus of the ice-ocean velocity   [m/s]
   REAL(wp), ALLOCATABLE, SAVE, DIMENSION(:,:) ::   soce_0  , sice_0     ! cst SSS and ice salinity (levitating sea-ice)

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
!! NEMO/LIM3 4.0 , UCL - NEMO Consortium (2011)
!! $Id: limsbc.F90 7753 2017-03-03 11:46:59Z mocavero $
!! Software governed by the CeCILL licence     (NEMOGCM/NEMO_CeCILL.txt)
!!----------------------------------------------------------------------
CONTAINS

   INTEGER FUNCTION lim_sbc_alloc()
!!-------------------------------------------------------------------
!!             ***  ROUTINE lim_sbc_alloc ***
!!-------------------------------------------------------------------
      ALLOCATE( soce_0(jpi,jpj) , utau_oce(jpi,jpj) ,                       &
         &      sice_0(jpi,jpj) , vtau_oce(jpi,jpj) , tmod_io(jpi,jpj), STAT=lim_sbc_alloc)
!
      IF( lk_mpp             )   CALL mpp_sum( lim_sbc_alloc )
      IF( lim_sbc_alloc /= 0 )   CALL ctl_warn('lim_sbc_alloc: failed to allocate arrays')
   END FUNCTION lim_sbc_alloc


   SUBROUTINE lim_sbc_flx( kt )
!!-------------------------------------------------------------------
!!                ***  ROUTINE lim_sbc_flx ***
!!
!! ** Purpose :   Update the surface ocean boundary condition for heat
!!              salt and mass over areas where sea-ice is non-zero
!!
!! ** Action  : - computes the heat and freshwater/salt fluxes
!!              at the ice-ocean interface.
!!              - Update the ocean sbc
!!
!! ** Outputs : - qsr     : sea heat flux:     solar
!!              - qns     : sea heat flux: non solar
!!              - emp     : freshwater budget: volume flux
!!              - sfx     : salt flux
!!              - fr_i    : ice fraction
!!              - tn_ice  : sea-ice surface temperature
!!              - alb_ice : sea-ice albedo (recomputed only for coupled mode)
!!
!! References : Goosse, H. et al. 1996, Bul. Soc. Roy. Sc. Liege, 65, 87-90.
!!              Tartinville et al. 2001 Ocean Modelling, 3, 95-108.
!!              These refs are now obsolete since everything has been revised
!!              The ref should be Rousset et al., 2015
!!---------------------------------------------------------------------
      INTEGER, INTENT(in) ::   kt   ! number of iteration
!
      INTEGER  ::   ji, jj, jl, jk   ! dummy loop indices
      REAL(wp) ::   zqmass           ! Heat flux associated with mass exchange ice->ocean (W.m-2)
      REAL(wp) ::   zqsr             ! New solar flux received by the ocean
      REAL(wp), POINTER, DIMENSION(:,:,:) ::   zalb_cs, zalb_os     ! 3D workspace
      REAL(wp), POINTER, DIMENSION(:,:)   ::   zalb                 ! 2D workspace
!!---------------------------------------------------------------------

! --- case we bypass ice thermodynamics --- !
      IF( .NOT. ln_limthd ) THEN   ! we suppose ice is impermeable => ocean is isolated from atmosphere
         hfx_in   (:,:)   = pfrld(:,:) * ( qns_oce(:,:) + qsr_oce(:,:) ) + qemp_oce(:,:)
         hfx_out  (:,:)   = pfrld(:,:) *   qns_oce(:,:)                  + qemp_oce(:,:)
         ftr_ice  (:,:,:) = 0._wp
         emp_ice  (:,:)   = 0._wp
         qemp_ice (:,:)   = 0._wp
         qevap_ice(:,:,:) = 0._wp
      ENDIF
      
! albedo output
      CALL wrk_alloc( jpi,jpj, zalb )    

      zalb(:,:) = 0._wp
      WHERE     ( at_i_b <= epsi06 )  ;  zalb(:,:) = 0.066_wp
      ELSEWHERE                       ;  zalb(:,:) = SUM( alb_ice * a_i_b, dim=3 ) / at_i_b
      END WHERE
      IF( iom_use('alb_ice' ) )  CALL iom_put( "alb_ice"  , zalb(:,:) )           ! ice albedo output

      zalb(:,:) = SUM( alb_ice * a_i_b, dim=3 ) + 0.066_wp * ( 1._wp - at_i_b )      
      IF( iom_use('albedo'  ) )  CALL iom_put( "albedo"  , zalb(:,:) )           ! ice albedo output

      CALL wrk_dealloc( jpi,jpj, zalb )    

      DO jj = 1, jpj
         DO ji = 1, jpi

!------------------------------------------!
!      heat flux at the ocean surface      !
!------------------------------------------!
! Solar heat flux reaching the ocean = zqsr (W.m-2)
!---------------------------------------------------
            zqsr = qsr_tot(ji,jj)
            DO jl = 1, jpl
               zqsr = zqsr - a_i_b(ji,jj,jl) * (  qsr_ice(ji,jj,jl) - ftr_ice(ji,jj,jl) ) 
            END DO

! Total heat flux reaching the ocean = hfx_out (W.m-2)
!---------------------------------------------------
            zqmass         = hfx_thd(ji,jj) + hfx_dyn(ji,jj) + hfx_res(ji,jj) ! heat flux from snow is 0 (T=0 degC)
            hfx_out(ji,jj) = hfx_out(ji,jj) + zqmass + zqsr

! Add the residual from heat diffusion equation and sublimation (W.m-2)
!----------------------------------------------------------------------
            hfx_out(ji,jj) = hfx_out(ji,jj) + hfx_err_dif(ji,jj) +   &
               &           ( hfx_sub(ji,jj) - SUM( qevap_ice(ji,jj,:) * a_i_b(ji,jj,:) ) )

! New qsr and qns used to compute the oceanic heat flux at the next time step
!----------------------------------------------------------------------------
            qsr(ji,jj) = zqsr                                      
            qns(ji,jj) = hfx_out(ji,jj) - zqsr              

!------------------------------------------!
!      mass flux at the ocean surface      !
!------------------------------------------!
!  case of realistic freshwater flux (Tartinville et al., 2001) (presently ACTIVATED)
!  -------------------------------------------------------------------------------------
!  The idea of this approach is that the system that we consider is the ICE-OCEAN system
!  Thus  FW  flux  =  External ( E-P+snow melt)
!       Salt flux  =  Exchanges in the ice-ocean system then converted into FW
!                     Associated to Ice formation AND Ice melting
!                     Even if i see Ice melting as a FW and SALT flux
!
! mass flux from ice/ocean
            wfx_ice(ji,jj) = wfx_bog(ji,jj) + wfx_bom(ji,jj) + wfx_sum(ji,jj) + wfx_sni(ji,jj)   &
                           + wfx_opw(ji,jj) + wfx_dyn(ji,jj) + wfx_res(ji,jj) + wfx_lam(ji,jj) 

! mass flux at the ocean/ice interface
            fmmflx(ji,jj) = - ( wfx_ice(ji,jj) + wfx_snw(ji,jj) + wfx_err_sub(ji,jj) )              ! F/M mass flux save at least for biogeochemical model
            emp(ji,jj)    = emp_oce(ji,jj) - wfx_ice(ji,jj) - wfx_snw(ji,jj) - wfx_err_sub(ji,jj)   ! mass flux + F/M mass flux (always ice/ocean mass exchange)
         END DO
      END DO

!------------------------------------------!
!      salt flux at the ocean surface      !
!------------------------------------------!
      sfx(:,:) = sfx_bog(:,:) + sfx_bom(:,:) + sfx_sum(:,:) + sfx_sni(:,:) + sfx_opw(:,:)   &
         &     + sfx_res(:,:) + sfx_dyn(:,:) + sfx_bri(:,:) + sfx_sub(:,:) + sfx_lam(:,:)

!-------------------------------------------------------------!
!   mass of snow and ice per unit area for embedded sea-ice   !
!-------------------------------------------------------------!
      IF( nn_ice_embd /= 0 ) THEN
! save mass from the previous ice time step
         snwice_mass_b(:,:) = snwice_mass(:,:)                  
! new mass per unit area
         snwice_mass  (:,:) = tmask(:,:,1) * ( rhosn * vt_s(:,:) + rhoic * vt_i(:,:)  ) 
! time evolution of snow+ice mass
         snwice_fmass (:,:) = ( snwice_mass(:,:) - snwice_mass_b(:,:) ) * r1_rdtice
      ENDIF

!-----------------------------------------------!
!   Storing the transmitted variables           !
!-----------------------------------------------!
      fr_i  (:,:)   = at_i(:,:)             ! Sea-ice fraction
      tn_ice(:,:,:) = t_su(:,:,:)           ! Ice surface temperature

!------------------------------------------------------------------------!
!    Snow/ice albedo (only if sent to coupler, useless in forced mode)   !
!------------------------------------------------------------------------!
      CALL wrk_alloc( jpi,jpj,jpl,   zalb_cs, zalb_os )    
      CALL albedo_ice( t_su, ht_i, ht_s, zalb_cs, zalb_os )  ! cloud-sky and overcast-sky ice albedos
      alb_ice(:,:,:) = ( 1. - cldf_ice ) * zalb_cs(:,:,:) + cldf_ice * zalb_os(:,:,:)
      CALL wrk_dealloc( jpi,jpj,jpl,   zalb_cs, zalb_os )

! conservation test
      IF( ln_limdiachk .AND. .NOT. ln_bdy)  CALL lim_cons_final( 'limsbc' )

! control prints
      IF( ln_limctl )   CALL lim_prt( kt, iiceprt, jiceprt, 3, ' - Final state lim_sbc - ' )
      IF( ln_ctl )      CALL lim_prt3D( 'limsbc' )

   END SUBROUTINE lim_sbc_flx


   SUBROUTINE lim_sbc_tau( kt , pu_oce, pv_oce )
!!-------------------------------------------------------------------
!!                ***  ROUTINE lim_sbc_tau ***
!!
!! ** Purpose : Update the ocean surface stresses due to the ice
!!
!! ** Action  : * at each ice time step (every nn_fsbc time step):
!!                - compute the modulus of ice-ocean relative velocity
!!                  (*rho*Cd) at T-point (C-grid) or I-point (B-grid)
!!                      tmod_io = rhoco * | U_ice-U_oce |
!!                - update the modulus of stress at ocean surface
!!                      taum = frld * taum + (1-frld) * tmod_io * | U_ice-U_oce |
!!              * at each ocean time step (every kt):
!!                  compute linearized ice-ocean stresses as
!!                      Utau = tmod_io * | U_ice - pU_oce |
!!                using instantaneous current ocean velocity (usually before)
!!
!!    NB: - ice-ocean rotation angle no more allowed
!!        - here we make an approximation: taum is only computed every ice time step
!!          This avoids mutiple average to pass from T -> U,V grids and next from U,V grids
!!          to T grid. taum is used in TKE and GLS, which should not be too sensitive to this approximaton...
!!
!! ** Outputs : - utau, vtau   : surface ocean i- and j-stress (u- & v-pts) updated with ice-ocean fluxes
!!              - taum         : modulus of the surface ocean stress (T-point) updated with ice-ocean fluxes
!!---------------------------------------------------------------------
      INTEGER ,                     INTENT(in) ::   kt               ! ocean time-step index
      REAL(wp), DIMENSION(jpi,jpj), INTENT(in) ::   pu_oce, pv_oce   ! surface ocean currents
!
      INTEGER  ::   ji, jj   ! dummy loop indices
      REAL(wp) ::   zat_u, zutau_ice, zu_t, zmodt   ! local scalar
      REAL(wp) ::   zat_v, zvtau_ice, zv_t, zrhoco  !   -      -
!!---------------------------------------------------------------------
      zrhoco = rau0 * rn_cio
!
      IF( MOD( kt-1, nn_fsbc ) == 0 ) THEN     !==  Ice time-step only  ==!   (i.e. surface module time-step)
         DO jj = 2, jpjm1                             !* update the modulus of stress at ocean surface (T-point)
            DO ji = 2, jpim1
!                                               ! 2*(U_ice-U_oce) at T-point
               zu_t = u_ice(ji,jj) + u_ice(ji-1,jj) - u_oce(ji,jj) - u_oce(ji-1,jj)   
               zv_t = v_ice(ji,jj) + v_ice(ji,jj-1) - v_oce(ji,jj) - v_oce(ji,jj-1) 
!                                              ! |U_ice-U_oce|^2
               zmodt =  0.25_wp * (  zu_t * zu_t + zv_t * zv_t  )
!                                               ! update the ocean stress modulus
               taum(ji,jj) = ( 1._wp - at_i(ji,jj) ) * taum(ji,jj) + at_i(ji,jj) * zrhoco * zmodt
               tmod_io(ji,jj) = zrhoco * SQRT( zmodt )          ! rhoco * |U_ice-U_oce| at T-point
            END DO
         END DO
         CALL lbc_lnk_multi( taum, 'T', 1., tmod_io, 'T', 1. )
!
         utau_oce(:,:) = utau(:,:)                    !* save the air-ocean stresses at ice time-step
         vtau_oce(:,:) = vtau(:,:)
!
      ENDIF
!
!                                      !==  every ocean time-step  ==!
!
      DO jj = 2, jpjm1                                !* update the stress WITHOUT a ice-ocean rotation angle
         DO ji = 2, jpim1   ! Vect. Opt.
            zat_u  = ( at_i(ji,jj) + at_i(ji+1,jj) ) * 0.5_wp   ! ice area at u and V-points
            zat_v  = ( at_i(ji,jj) + at_i(ji,jj+1) ) * 0.5_wp
!                                                   ! linearized quadratic drag formulation
            zutau_ice   = 0.5_wp * ( tmod_io(ji,jj) + tmod_io(ji+1,jj) ) * ( u_ice(ji,jj) - pu_oce(ji,jj) )
            zvtau_ice   = 0.5_wp * ( tmod_io(ji,jj) + tmod_io(ji,jj+1) ) * ( v_ice(ji,jj) - pv_oce(ji,jj) )
!                                                   ! stresses at the ocean surface
            utau(ji,jj) = ( 1._wp - zat_u ) * utau_oce(ji,jj) + zat_u * zutau_ice
            vtau(ji,jj) = ( 1._wp - zat_v ) * vtau_oce(ji,jj) + zat_v * zvtau_ice
         END DO
      END DO
      CALL lbc_lnk_multi( utau, 'U', -1., vtau, 'V', -1. )   ! lateral boundary condition
!
!
   END SUBROUTINE lim_sbc_tau


   SUBROUTINE lim_sbc_init
!!-------------------------------------------------------------------
!!                  ***  ROUTINE lim_sbc_init  ***
!!
!! ** Purpose : Preparation of the file ice_evolu for the output of
!!      the temporal evolution of key variables
!!
!! ** input   : Namelist namicedia
!!-------------------------------------------------------------------
      INTEGER  ::   ji, jj, jk               ! dummy loop indices
      REAL(wp) ::   zcoefu, zcoefv, zcoeff   ! local scalar
!!-------------------------------------------------------------------
!
      IF(lwp) WRITE(numout,*)
      IF(lwp) WRITE(numout,*) 'lim_sbc_init : LIM-3 sea-ice - surface boundary condition'
      IF(lwp) WRITE(numout,*) '~~~~~~~~~~~~~   '

!                                      ! allocate lim_sbc array
      IF( lim_sbc_alloc() /= 0 )   CALL ctl_stop( 'STOP', 'lim_sbc_init : unable to allocate standard arrays' )
!
      soce_0(:,:) = soce                     ! constant SSS and ice salinity used in levitating sea-ice case
      sice_0(:,:) = sice
!                                      ! decrease ocean & ice reference salinities in the Baltic Sea area
      WHERE( 14._wp <= glamt(:,:) .AND. glamt(:,:) <= 32._wp .AND.   &
         &   54._wp <= gphit(:,:) .AND. gphit(:,:) <= 66._wp         ) 
         soce_0(:,:) = 4._wp
         sice_0(:,:) = 2._wp
      END WHERE
!
      IF( .NOT. ln_rstart ) THEN
!                                      ! embedded sea ice
         IF( nn_ice_embd /= 0 ) THEN            ! mass exchanges between ice and ocean (case 1 or 2) set the snow+ice mass
            snwice_mass  (:,:) = tmask(:,:,1) * ( rhosn * vt_s(:,:) + rhoic * vt_i(:,:)  )
            snwice_mass_b(:,:) = snwice_mass(:,:)
         ELSE
            snwice_mass  (:,:) = 0._wp          ! no mass exchanges
            snwice_mass_b(:,:) = 0._wp          ! no mass exchanges
         ENDIF
         IF( nn_ice_embd == 2 ) THEN            ! full embedment (case 2) deplete the initial ssh below sea-ice area
            sshn(:,:) = sshn(:,:) - snwice_mass(:,:) * r1_rau0
            sshb(:,:) = sshb(:,:) - snwice_mass(:,:) * r1_rau0

!!gm I really don't like this stuff here...  Find a way to put that elsewhere or differently
!!gm
            IF( .NOT.ln_linssh ) THEN
               DO jk = 1,jpkm1                     ! adjust initial vertical scale factors
                  e3t_n(:,:,jk) = e3t_0(:,:,jk)*( 1._wp + sshn(:,:)*tmask(:,:,1)/(ht_0(:,:) + 1.0 - tmask(:,:,1)) )
                  e3t_b(:,:,jk) = e3t_0(:,:,jk)*( 1._wp + sshb(:,:)*tmask(:,:,1)/(ht_0(:,:) + 1.0 - tmask(:,:,1)) )
               END DO
               e3t_a(:,:,:) = e3t_b(:,:,:)
! Reconstruction of all vertical scale factors at now and before time-steps
! =========================================================================
! Horizontal scale factor interpolations
! --------------------------------------
               CALL dom_vvl_interpol( e3t_b(:,:,:), e3u_b(:,:,:), 'U' )
               CALL dom_vvl_interpol( e3t_b(:,:,:), e3v_b(:,:,:), 'V' )
               CALL dom_vvl_interpol( e3t_n(:,:,:), e3u_n(:,:,:), 'U' )
               CALL dom_vvl_interpol( e3t_n(:,:,:), e3v_n(:,:,:), 'V' )
               CALL dom_vvl_interpol( e3u_n(:,:,:), e3f_n(:,:,:), 'F' )
! Vertical scale factor interpolations
! ------------------------------------
               CALL dom_vvl_interpol( e3t_n(:,:,:), e3w_n (:,:,:), 'W'  )
               CALL dom_vvl_interpol( e3u_n(:,:,:), e3uw_n(:,:,:), 'UW' )
               CALL dom_vvl_interpol( e3v_n(:,:,:), e3vw_n(:,:,:), 'VW' )
               CALL dom_vvl_interpol( e3u_b(:,:,:), e3uw_b(:,:,:), 'UW' )
               CALL dom_vvl_interpol( e3v_b(:,:,:), e3vw_b(:,:,:), 'VW' )
! t- and w- points depth
! ----------------------
!!gm not sure of that....
               gdept_n(:,:,1) = 0.5_wp * e3w_n(:,:,1)
               gdepw_n(:,:,1) = 0.0_wp
               gde3w_n(:,:,1) = gdept_n(:,:,1) - sshn(:,:)
               DO jk = 2, jpk
                  gdept_n(:,:,jk) = gdept_n(:,:,jk-1) + e3w_n(:,:,jk)
                  gdepw_n(:,:,jk) = gdepw_n(:,:,jk-1) + e3t_n(:,:,jk-1)
                  gde3w_n(:,:,jk) = gdept_n(:,:,jk  ) - sshn   (:,:)
               END DO
            ENDIF
         ENDIF
      ENDIF ! .NOT. ln_rstart
!
   END SUBROUTINE lim_sbc_init



!!======================================================================
END MODULE limsbc
