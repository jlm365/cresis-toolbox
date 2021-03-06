function [success] = csarp_task(param)
% [success] = csarp_task(param)
%
% SAR process a chunk of data (a frame is divided into chunks
% to keep the memory requirements low enough).  This function
% is called from csarp.m.
%
% param = structure controlling the SAR processor
%  .debug_level = scalar integer, debugging level
%  .radar = structured used by load_mcords_hdr
%
%  .load = structure containing info about what data to load
%   .records_fn = records filename
%   .recs = 2 element vector containing the start and stop records
%   .imgs = cell vector of images to load, each image is Nx2 array of
%     wf/adc pairs
%     NOTE: wfs/ads are not indices into anything, they are the absolute
%     waveform/adc numbers. The records file will be loaded to decode
%     which index each wf/adc belongs to.
%
%  .proc = structure about which frame to process and how it is broken
%    into chunks
%   .frm = only used to determine the file name of the output
%   .output_along_track_offset = along-track offset from first input
%      record to the first output range line
%   .output_along_track_Nx = length of output in along-track
%
%  .csarp = structure containing SAR processing parameters
%   .file = struct with input file information
%      .base_dir: string, e.g. '/cresis/data3/MCoRDS/2011_Greenland_P3/'
%      .adc_folder_name = string, e.g. '20110507/board%b/seg_01'
%      .file_prefix = string, e.g. ''
%   .out_path = output path string
%   .combine_rx = boolean, combine channels before SAR processing
%   .coh_noise_removal = boolean, slow-time DC removal
%   .lever_arm_fh = string containing function name to lever arm
%   .mocomp = struct for motion compensation
%      .en = boolean, apply motion compensation
%      .type = see motion_comp.m for details
%      .uniform_en = boolean, resample data to uniform sampling in along-track
%   .sar_type = string, 'fk' or 'tdbp'
%   .sigma_x = along-track output sample spacing (meters)
%   .sub_aperture_steering = vector of doppler centroids to process to
%     (i.e. subapertures) normalized to the doppler bandwidth
%   .st_wind = function handle for slow time decimation
%   .start_eps = epsilon to use for sub-surface
%
% Fields used by load_mcords_data.m (see that function for details)
%  .pulse_rfi.en
%  .pulse_rfi.inc_ave
%  .pulse_rfi.thresh_scale
%  .trim_vals
%  .pulse_comp
%  .ft_dec
%  .ft_wind
%  .ft_wind_time
%  .radar.rx_path.chan_equal
%  .radar.rx_path.td
%
% success = boolean which is true when the function executes properly
%   if a task fails before it can return success, then success will be
%   empty
%
% Authors: William Blake, John Paden
%
% See also: csarp.m
%

%% Initialization and checking arguments

% Get speed of light, dielectric of ice constants
physical_constants;
wgs84 = wgs84Ellipsoid('meters');

global g_data; g_data = [];

[output_dir,radar_type,radar_name] = ct_output_dir(param.radar_name);

records_fn = ct_filename_support(param,'','records');
records = load(records_fn,'settings','param_records');

if param.csarp.combine_rx && param.csarp.mocomp.en
  warning('CSARP motion compensation mode must be 0 for combine_rx (setting to 0)');
  param.csarp.mocomp.en = 0;
end

% SAR output directory
csarp_out_dir = ct_filename_out(param, param.csarp.out_path);
csarp_coord_dir = ct_filename_out(param, param.csarp.coord_path);

% Load SAR coordinate system
sar_fn = fullfile(csarp_coord_dir,'sar_coord.mat');
sar = load(sar_fn,'version','Lsar','gps_source','type','sigma_x','presums','along_track','surf_pp');

% Determine output range lines
output_along_track = 0 : param.csarp.sigma_x : sar.along_track(end);
start_x = sar.along_track(param.load.recs(1));
stop_x = sar.along_track(param.load.recs(2));
out_rlines = find(output_along_track >= start_x & output_along_track <= stop_x);
output_along_track = output_along_track(out_rlines);

%% Collect waveform information into one structure
%  - This is used to break the frame up into chunks
% =====================================================================
if strcmpi(radar_name,'mcrds')
  wfs = load_mcrds_wfs(records.settings, param, ...
    records.param_records.records.file.adcs, param.csarp);
elseif any(strcmpi(radar_name,{'acords','hfrds','hfrds2','mcords','mcords2','mcords3','mcords4','mcords5','seaice','accum2'}))
  wfs = load_mcords_wfs(records.settings, param, ...
    records.param_records.records.file.adcs, param.csarp);
elseif any(strcmpi(radar_name,{'icards'}))% add icards---qishi
  wfs = load_icards_wfs(records.settings, param, ...
    records.param_records.records.file.adcs, param.csarp);
elseif any(strcmpi(radar_name,{'snow','kuband','snow2','kuband2','snow3','kuband3','kaband3','snow5'}))
  error('Not supported');
  wfs = load_fmcw_wfs(records.settings, param, ...
    records.param_records.records.file.adcs, param.csarp);
  for wf=1:length(wfs)
    wfs(wf).time = param.csarp.time_of_full_support;
    wfs(wf).freq = 1;
  end
elseif strcmpi(radar_name,'sim');
end

%% Determine chunk overlap to ensure full support
% =====================================================================
% Determine overlap of chunks from the range to furthest target
times    = cell2mat({wfs.time}.');
max_time = min(max(times),param.csarp.time_of_full_support);

% wavelength (m)
wf = abs(param.load.imgs{1}(1,1));
lambda = c/wfs(wf).fc;
% twtt to surface (sec)
surf_time = ppval(sar.surf_pp, start_x); surf_time = min(max_time,surf_time);
% effective in air max range (m)
max_range = ((max_time-surf_time)/sqrt(param.csarp.start_eps) + surf_time) * c/2;
% chunk overlap (m)
chunk_overlap_start = (max_range*lambda)/(2*param.csarp.sigma_x) / 2;
% chunk_overlap_start = max_range/sqrt((2*param.csarp.sigma_x/lambda)^2-1);

% twtt to surface (sec)
surf_time = ppval(sar.surf_pp, stop_x); surf_time = min(max_time,surf_time);
% effective in air max range (m)
max_range = ((max_time-surf_time)/sqrt(param.csarp.start_eps) + surf_time) * c/2;
chunk_overlap_stop = (max_range*lambda)/(2*param.csarp.sigma_x) / 2;
% chunk_overlap_stop = max_range/sqrt((2*param.csarp.sigma_x/lambda)^2-1);

% These are the records which will be used
cur_recs = [find(sar.along_track > start_x-chunk_overlap_start,1) ...
  find(sar.along_track < stop_x+chunk_overlap_stop, 1, 'last')];
param.load.recs = cur_recs;

%% Determine zero padding to prevent circular convolution aliasing
% =====================================================================
param.load.start_zero_pad = floor((sar.along_track(cur_recs(1)) - (start_x-chunk_overlap_start)) / param.csarp.sigma_x);
param.load.stop_zero_pad = floor((stop_x+chunk_overlap_stop - sar.along_track(cur_recs(2))) / param.csarp.sigma_x);

%% Prepare trajectory information
% =========================================================================

% Create along-track vectors (output rline 1 is zero/origin)
along_track = sar.along_track(param.load.recs(1):param.load.recs(end));

% Create FCS: SAR (flight) coordinate system
fcs = [];
fcs.Lsar = sar.Lsar;
fcs.gps_source = sar.gps_source;

% Slow, but memory efficient way to load SAR coordinate system
tmp = load(sar_fn,'origin');
fcs.origin = tmp.origin(:,out_rlines);
tmp = load(sar_fn,'x');
fcs.x = tmp.x(:,out_rlines);
tmp = load(sar_fn,'z');
fcs.z = tmp.z(:,out_rlines);
fcs.y = cross(fcs.z,fcs.x);
% fcs.pos: to be added for each individual SAR image
tmp = load(sar_fn,'roll');
fcs.roll = tmp.roll(1,out_rlines);
tmp = load(sar_fn,'pitch');
fcs.pitch = tmp.pitch(1,out_rlines);
tmp = load(sar_fn,'heading');
fcs.heading = tmp.heading(1,out_rlines);
tmp = load(sar_fn,'gps_time');
fcs.gps_time = tmp.gps_time(1,out_rlines);

fcs.surface = ppval(sar.surf_pp,output_along_track);
fcs.bottom = NaN*ones(size(fcs.surface));

%% Load record information
% =====================================================================
load_param = param;
load_param.load.recs = [(param.load.recs(1)-1)*param.csarp.presums+1, ...
        param.load.recs(2)*param.csarp.presums];
orig_records = read_records_aux_files(records_fn,load_param.load.recs);
all_records = orig_records;
%Decimate orig_records and ref according to presums
if param.csarp.presums > 1
  orig_records.lat = fir_dec(orig_records.lat,param.csarp.presums);
  orig_records.lon = fir_dec(orig_records.lon,param.csarp.presums);
  orig_records.elev = fir_dec(orig_records.elev,param.csarp.presums);
  orig_records.roll = fir_dec(orig_records.roll,param.csarp.presums);
  orig_records.pitch = fir_dec(orig_records.pitch,param.csarp.presums);
  orig_records.heading = fir_dec(orig_records.heading,param.csarp.presums);
  orig_records.gps_time = fir_dec(orig_records.gps_time,param.csarp.presums);
  orig_records.surface = fir_dec(orig_records.surface,param.csarp.presums);
end
old_param_records = orig_records.param_records;
old_param_records.gps_source = orig_records.gps_source;

%% Get the new surface
% =====================================================================
if isfield(param.csarp,'surface_src') && ~isempty(param.csarp.surface_src)
  
  % Get the generic layer data path
  layer_path = fullfile(ct_filename_out(param,param.csarp.surface_src,'',0));
  
  % Load the current frame
  layer_fn = fullfile(layer_path,sprintf('Data_%s_%03d.mat',param.day_seg,param.proc.frm));
  layer = load(layer_fn);
  new_surface_gps_time = layer.GPS_time;
  new_surface = layer.layerData{1}.value{2}.data;
  % Get the previous frame if necessary
  if orig_records.gps_time(1) < new_surface_gps_time(1)-1
    layer_fn = fullfile(layer_path,sprintf('Data_%s_%03d.mat',param.day_seg,param.proc.frm-1));
    if exist(layer_fn,'file')
      layer = load(layer_fn);
      new_surface_gps_time = [layer.GPS_time new_surface_gps_time];
      new_surface = [layer.layerData{1}.value{2}.data new_surface];
    end
  end
  % Get the next frame if necessary
  if orig_records.gps_time(end) > new_surface_gps_time(end)+1
    layer_fn = fullfile(layer_path,sprintf('Data_%s_%03d.mat',param.day_seg,param.proc.frm+1));
    if exist(layer_fn,'file')
      layer = load(layer_fn);
      new_surface_gps_time = [new_surface_gps_time layer.GPS_time];
      new_surface = [new_surface layer.layerData{1}.value{2}.data];
    end
  end
  % Since layer files may have overlapping data, sort it
  [new_surface_gps_time new_surface_idxs] = sort(new_surface_gps_time);
  new_surface = new_surface(new_surface_idxs);
  
  % Do the interpolation and overwrite the orig_records.surface variable
  new_surface = interp1(new_surface_gps_time,new_surface,orig_records.gps_time,'linear','extrap');
  orig_records.surface = new_surface;
end

%% Load waveforms and record data size
% =========================================================================
if strcmpi(radar_name,'mcrds')
  [wfs,rec_data_size] = load_mcrds_wfs(orig_records.settings, param, ...
    1:max(old_param_records.records.file.adcs), param.csarp);
  load_param.load.rec_data_size = rec_data_size;
elseif any(strcmpi(radar_name,{'acords','hfrds','hfrds2','mcords','mcords2','mcords3','mcords4','mcords5','seaice','accum2'}))
  [wfs,rec_data_size] = load_mcords_wfs(orig_records.settings, param, ...
    1:max(old_param_records.records.file.adcs), param.csarp);
  load_param.load.rec_data_size = rec_data_size;
elseif any(strcmpi(radar_name,{'icards'}))% add icards----qishi
  [wfs,rec_data_size] = load_icards_wfs(orig_records.settings, param, ...
    1:max(old_param_records.records.file.adcs), param.csarp);
    load_param.load.rec_data_size = rec_data_size;
elseif any(strcmpi(radar_name,{'snow','kuband','snow2','kuband2','snow3','kuband3','kaband3','snow5'}))
  wfs = load_fmcw_wfs(orig_records.settings, param, ...
    1:max(old_param_records.records.file.adcs), param.csarp);
end
load_param.wfs                = wfs;

%% Collect record file information required for using raw data loaders
%  - Performs mapping between param.adcs and the records file contents
%  - Translates filenames from relative to absolute
%  - Makes filenames have the correct filesep
% =====================================================================

% Create a list of unique receivers required by the imgs list
param.load.adcs = [];
for idx = 1:length(param.load.imgs)
  param.load.adcs = unique(cat(2, ...
    abs(param.load.imgs{idx}(:,2)).', param.load.adcs));
end

if any(strcmpi(radar_name,{'hfrds','hfrds2','icards','mcords','mcords2','mcords3','mcords4','mcords5','seaice','accum2'}))
  % adc_headers: the actual adc headers that were loaded
  if ~isfield(old_param_records.records.file,'adc_headers') || isempty(old_param_records.records.file.adc_headers)
    old_param_records.records.file.adc_headers = old_param_records.records.file.adcs;
  end
  
  % boards_headers: the boards that the actual adc headers were loaded from
  boards_headers = adc_to_board(param.radar_name,old_param_records.records.file.adcs);
  
  for idx = 1:length(param.load.adcs)
    % adc: the specific ADC we would like to load
    adc = param.load.adcs(idx);
    % adc_idx: the records file index for this adc
    adc_idx = find(old_param_records.records.file.adcs == adc);
    if isempty(adc_idx)
      error('ADC %d not present in records file\n', adc);
    end
    
    % board: the board associated with the ADC we would like to load
    board = adc_to_board(param.radar_name,adc);
    % board_header: the board headers that we will use with this ADC
    board_header = adc_to_board(param.radar_name,old_param_records.records.file.adc_headers(adc_idx));
    % board_idx: the index into the records board list to use
    board_idx = find(board_header == boards_headers);
    
    % Just get the file-information for the records we need
    load_param.load.file_idx{idx} = relative_rec_num_to_file_idx_vector( ...
      load_param.load.recs,orig_records.relative_rec_num{board_idx});
    load_param.load.offset{idx} = orig_records.offset(board_idx,:);
    file_idxs = unique(load_param.load.file_idx{idx});
    
    % Recognize if first record is really from previous file and it is a
    % valid record (i.e. offset does not equal -2^31)
    if sign(load_param.load.offset{idx}(1)) < 0 && load_param.load.offset{idx}(1) ~= -2^31
      file_idxs = [file_idxs(1)-1 file_idxs];
    end
    
    % Just copy the filenames we need
    load_param.load.filenames{idx}(file_idxs) = orig_records.relative_filename{board_idx}(file_idxs);

    % Modify filename according to channel
    for file_idx = 1:length(load_param.load.filenames{idx})
      if any(strcmpi(radar_name,{'mcords5'}))
        load_param.load.filenames{idx}{file_idx}(9:10) = sprintf('%02d',board);
      end
    end
    
    filepath = get_segment_file_list(param,adc);
    
    % Convert relative file paths into absolute file paths if required,
    % also corrects filesep (\ and /)
    for file_idx = 1:length(load_param.load.filenames{idx})
      load_param.load.filenames{idx}{file_idx} ...
        = fullfile(filepath,load_param.load.filenames{idx}{file_idx});
    end
  end
  load_param.load.file_version = param.records.file_version;
  load_param.load.wfs = orig_records.settings.wfs;
elseif strcmpi(radar_name,'mcrds')
  load_param.load.offset = orig_records.offset;
  load_param.load.file_rec_offset = orig_records.relative_rec_num;
  load_param.load.filenames = orig_records.relative_filename;
  base_dir = ct_filename_data(param,param.vectors.file.base_dir);
  adc_folder_name = param.vectors.file.adc_folder_name;
  load_param.load.filepath = fullfile(base_dir, adc_folder_name);
  load_param.load.wfs = orig_records.settings.wfs;
  load_param.load.wfs_records = orig_records.settings.wfs_records;  
elseif strcmpi(radar_name,'acords')
  load_param.load.offset = orig_records.offset;
  load_param.load.file_rec_offset = orig_records.relative_rec_num;
  load_param.load.filenames = orig_records.relative_filename;
  base_dir = ct_filename_data(param,param.vectors.file.base_dir);
  adc_folder_name = param.vectors.file.adc_folder_name;
  load_param.load.filepath = fullfile(base_dir, adc_folder_name);
  load_param.load.wfs = orig_records.settings.wfs;
  load_param.load.wfs_records = orig_records.settings.wfs_records;
elseif strcmpi(radar_name,'icards')% add icards---qishi
  load_param.load.offset = orig_records.offset;
  load_param.load.file_rec_offset = orig_records.relative_rec_num;
  load_param.load.filenames = orig_records.relative_filename;
  base_dir = ct_filename_data(param,param.vectors.file.base_dir);
  adc_folder_name = param.vectors.file.adc_folder_name;
  load_param.load.filepath = fullfile(base_dir, adc_folder_name);
  load_param.load.wfs = orig_records.settings.wfs;
  load_param.load.wfs_records = orig_records.settings.wfs_records; 
elseif any(strcmpi(radar_name,{'snow','kuband','snow2','kuband2','snow3','kuband3','kaband3','snow5'}))
  % Determine which ADC boards are supported and which ones were actually loaded
  if ~isfield(old_param_records.records.file,'adc_headers') || isempty(old_param_records.records.file.adc_headers)
    old_param_records.records.file.adc_headers = old_param_records.records.file.adcs;
  end
  boards = adc_to_board(param.radar_name,old_param_records.records.file.adcs);
  boards_headers = adc_to_board(param.radar_name,old_param_records.records.file.adc_headers);
  
  for idx = 1:length(param.load.adcs)
    adc = param.load.adcs(idx);
    adc_idx = find(old_param_records.records.file.adcs == param.load.adcs(idx));
    if isempty(adc_idx)
      error('ADC %d not present in records file\n', param.load.adcs(idx));
    end
    
    % Just get the file-information for the records we need
    board = adc_to_board(param.radar_name,adc);
    actual_board_idx = find(board == boards);
    board_idx = find(old_param_records.records.file.adc_headers(actual_board_idx) == boards_headers);
    load_param.load.file_idx{idx} = relative_rec_num_to_file_idx_vector( ...
      load_param.load.recs,orig_records.relative_rec_num{board_idx});
    load_param.load.offset{idx} = orig_records.offset(board_idx,:);
    file_idxs = unique(load_param.load.file_idx{idx});
    
    % Recognize if first record is really from previous file and it is a
    % valid record (i.e. offset does not equal -2^31)
    if sign(load_param.load.offset{idx}(1)) < 0 && load_param.load.offset{idx}(1) ~= -2^31
      file_idxs = [file_idxs(1)-1 file_idxs];
    end
    
    % Just copy the filenames we need
    load_param.load.filenames{idx}(file_idxs) = orig_records.relative_filename{board_idx}(file_idxs);
    
    % Modify filename according to channel
    for file_idx = 1:length(load_param.load.filenames{idx})
      if ~isequal(old_param_records.records.file.adc_headers,old_param_records.records.file.adcs)
        load_param.load.filenames{idx}{file_idx}(9:10) = sprintf('%02d',board);
      end
    end
    
    filepath = get_segment_file_list(param,adc);
    
    % Convert relative file paths into absolute file paths if required,
    % also corrects filesep (\ and /)
    for file_idx = 1:length(load_param.load.filenames{idx})
      load_param.load.filenames{idx}{file_idx} ...
        = fullfile(filepath,load_param.load.filenames{idx}{file_idx});
    end
  end
  load_param.load.file_version = param.records.file_version;

else
  error('Radar name %s not supported', param.radar_name);
end

%% Setup control parameters for loading data
% =====================================================================

load_param.load.adcs = param.load.adcs;

load_param.proc.pulse_comp         = param.csarp.pulse_comp;
load_param.proc.ft_dec             = param.csarp.ft_dec;
load_param.proc.ft_wind            = param.csarp.ft_wind;
load_param.proc.ft_wind_time       = param.csarp.ft_wind_time;
load_param.proc.presums            = param.csarp.presums;
load_param.proc.combine_rx         = param.csarp.combine_rx;
load_param.proc.pulse_rfi          = param.csarp.pulse_rfi;
load_param.proc.trim_vals          = param.csarp.trim_vals;
load_param.proc.coh_noise_method   = param.csarp.coh_noise_method;
load_param.proc.coh_noise_arg      = param.csarp.coh_noise_arg;

load_param.surface = orig_records.surface;
if strcmpi(radar_name,'acords')
  load_param.load.file_version = param.records.file_version;
end

%% Load and Pulse Compress Data
% =====================================================================
% Load data into g_data using load_mcords_data
load_param.load.imgs = param.load.imgs;

if strcmpi(radar_name,'mcords')
  %   if strcmpi(param.season_name,'mcords_simulator')
  %     load_param.fn = get_filename(base_dir,'','','mat');
  %     load_simulated_data(load_param);
  %   else
  load_mcords_data(load_param);
  %   end
elseif any(strcmpi(radar_name,{'hfrds','hfrds2','mcords2','mcords3','mcords4','mcords5','seaice'}))
  load_mcords2_data(load_param,all_records);
elseif strcmpi(radar_name,'accum2')
  load_accum2_data(load_param);
elseif strcmpi(radar_name,'acords')
  load_acords_data(load_param);
elseif strcmpi(radar_name,'mcrds')
  if isfield(orig_records,'adc_phase_corr_deg') && isfield(param.radar,'adc_phase_corr_en') && param.radar.adc_phase_corr_en
    load_param.adc_phase_corr_deg = orig_records.adc_phase_corr_deg;
  else
    load_param.adc_phase_corr_deg = zeros(length(load_param.surface),max(orig_records.param_records.records.file.adcs));
  end
  load_mcrds_data(load_param);
elseif strcmpi(radar_name,'icards')
  load_icards_data(load_param,param);
elseif any(strcmpi(radar_name,{'snow','kuband','snow2','kuband2','snow3','kuband3','kaband3','snow5'}))
  load_param.proc.elev_correction = 0;%param.csarp.elev_correction;
  load_param.proc.deconvolution = param.csarp.deconvolution;
  load_param.proc.psd_smooth = param.csarp.psd_smooth;
  load_param.radar_name = param.radar_name;
  load_param.season_name = param.season_name;
  load_param.day_seg = param.day_seg;
  load_param.load.tmp_path = param.tmp_path;
  load_param.out_path = param.out_path;
  [img_time,img_valid_rng,img_deconv_filter_idx,img_freq] = load_fmcw_data(load_param,orig_records);
  valid_rng = img_valid_rng{1};
  deconv_filter_idx = img_deconv_filter_idx{1};
  for wf = 1:length(wfs)
    wfs(wf).time = img_time{1};
    wfs(wf).freq = img_freq{1};
  end
elseif strcmpi(radar_name,'sim');
  
end

%% Prepare reference trajectory information
% =========================================================================

% Load reference trajectory
trajectory_param = struct('gps_source',orig_records.gps_source, ...
  'season_name',param.season_name,'radar_name',param.radar_name,'rx_path', 0, ...
  'tx_weights', [], 'lever_arm_fh', param.csarp.lever_arm_fh);
ref = trajectory_with_leverarm(orig_records,trajectory_param);


% Resample reference trajectory at output positions
% 1. Convert ref trajectory to ecef
ecef = zeros(3,size(ref.lat,2));
[ecef(1,:) ecef(2,:) ecef(3,:)] = geodetic2ecef(ref.lat/180*pi, ref.lon/180*pi, ref.elev, WGS84.ellipsoid);
% 2. Resample based on input and output along track
ecef = interp1(along_track,ecef.',output_along_track,'linear','extrap').';
% 3. Convert ecef to geodetic
[lat,lon,elev] = ecef2geodetic(ecef(1,:), ecef(2,:), ecef(3,:), WGS84.ellipsoid);
lat = lat*180/pi;
lon = lon*180/pi;
%% Remove coherent noise
% =========================================================================
if param.csarp.coh_noise_method && ~any(strcmpi(radar_name,{'kuband','snow','kuband2','snow2','kuband3','kaband3','snow3','snow5'}))
  
  if param.csarp.coh_noise_method == 3 && isempty(param.csarp.coh_noise_arg)
    param.csarp.coh_noise_arg = 255;
  end
  
  % DC and near-DC REMOVAL
  if param.csarp.ground_based
    % Only remove coherent noise from sections which are moving
    vel = diff(along_track) ./ diff(orig_records.gps_time);
    good_mask = vel > median(vel)/5;
    % figure(1); clf;
    % plot(vel);
    % hold on;
    % vel(~good_mask) = NaN;
    % plot(vel,'r');
    % hold off;
    for idx=1:length(g_data)
      % Transpose for faster memory access
      g_data{idx} = permute(g_data{idx},[2 1 3]);
      for rbin = 1:size(g_data{idx},2)
        for wf_adc_idx = 1:size(g_data{idx},3)
          if param.csarp.coh_noise_method == 1
            g_data{idx}(:,rbin,wf_adc_idx) = g_data{idx}(:,rbin,wf_adc_idx) - mean(g_data{idx}(good_mask,rbin,wf_adc_idx));
          else
            error('param.csarp.coh_noise_method %d not supported.',param.csarp.coh_noise_method);
          end
        end
      end
      % Undo transpose
      g_data{idx} = permute(g_data{idx},[2 1 3]);
    end
  else
    % Remove only the DC Doppler component
    for idx=1:length(g_data)
      for wf_adc_idx = 1:size(g_data{idx},3)
        if param.csarp.coh_noise_method == 1
          g_data{idx}(:,:,wf_adc_idx) = bsxfun(@minus, g_data{idx}(:,:,wf_adc_idx), ...
            mean(g_data{idx}(:,:,wf_adc_idx),2));
        elseif param.csarp.coh_noise_method == 3
          g_data{idx}(:,:,wf_adc_idx) = bsxfun(@minus, g_data{idx}(:,:,wf_adc_idx), ...
            fir_dec(g_data{idx}(:,:,wf_adc_idx),hanning(param.csarp.coh_noise_arg).'/(param.csarp.coh_noise_arg/2+0.5),1));
        end
      end
    end
  end
end

%% Main loop to process each image
% =========================================================================
for img_idx = 1:length(load_param.load.imgs)
  if param.csarp.combine_rx
    % Receivers combined, so just run the first wf/adc pair
    imgs_list = load_param.load.imgs{1}(1,:);
  else
    % Receivers processed individually, so get information for all wf/adc pairs.
    imgs_list = load_param.load.imgs{img_idx};
  end
  
  %% Loop to process each wf-adc pair
  for wf_adc_idx = 1:size(imgs_list,1)
    % Processing loop
    % Runs once for combine_rx = true
    % Runs for each wf/adc pair in image if combine_rx = false
    
    wf = abs(imgs_list(wf_adc_idx,1));
    adc = abs(imgs_list(wf_adc_idx,2));
    
    %% Compute trajectory, SAR phase center and coordinate system
    if isempty(param.csarp.lever_arm_fh)
      records = orig_records;
    else
      if ~param.csarp.combine_rx
        % Create actual trajectory
        trajectory_param = struct('gps_source',orig_records.gps_source, ...
          'season_name',param.season_name,'radar_name',param.radar_name, ...
          'rx_path', wfs(wf).rx_paths(adc), ...
          'tx_weights', wfs(wf).tx_weights, 'lever_arm_fh', param.csarp.lever_arm_fh);
        records = trajectory_with_leverarm(orig_records,trajectory_param);
      else
        trajectory_param = struct('gps_source',orig_records.gps_source, ...
          'season_name',param.season_name,'radar_name',param.radar_name, ...
          'rx_path', wfs(wf).rx_paths(adc), ...
          'tx_weights', wfs(wf).tx_weights, 'lever_arm_fh', param.csarp.lever_arm_fh);
        for tmp_wf_adc_idx = 2:size(load_param.load.imgs{1},1)
          tmp_wf = abs(load_param.load.imgs{1}(tmp_wf_adc_idx,1));
          tmp_adc = abs(load_param.load.imgs{1}(tmp_wf_adc_idx,2));
          trajectory_param.rx_path(tmp_wf_adc_idx) = wfs(tmp_wf).rx_paths(tmp_adc);
        end
        records = trajectory_with_leverarm(orig_records,trajectory_param);
      end
    end

    % Create fcs.pos: phase center in the flight coordinate system
    % 1. Convert phase center trajectory to ecef
    ecef = zeros(3,size(records.lat,2));
    [ecef(1,:),ecef(2,:),ecef(3,:)] ...
      = geodetic2ecef(wgs84,records.lat,records.lon,records.elev);

    % 2. Use the fcs to convert ecef to fcs coordinates and store in fcs.pos
    Nx = size(fcs.origin,2);
    good_rline = logical(ones(1,Nx));
    for out_rline = 1:Nx
      % For this output range line determine the input range lines
      rlines_in = find(along_track >= output_along_track(out_rline)-fcs.Lsar/2 ...
        & along_track <= output_along_track(out_rline)+fcs.Lsar/2);
      if isempty(rlines_in)
        % Sometimes there are gaps in the data, we will use neighboring points
        % to fill in these gaps
        good_rline(out_rline) = 0;
        continue;
      end
      fcs.pos(:,out_rline) = [fcs.x(:,out_rline) fcs.y(:,out_rline) fcs.z(:,out_rline)] \ (mean(ecef(:,rlines_in),2) - fcs.origin(:,out_rline));
    end
    if ~any(good_rline)
      error('Data gap extends across entire chunk. Consider breaking segment into two at this gap or increasing the chunk size.');
    end

    % 3. Fill in any missing lines
    fcs.pos(:,~good_rline) = interp1(output_along_track(good_rline),fcs.pos(:,good_rline).',output_along_track(~good_rline).','linear','extrap').';
    
    
    %% SAR Processing
    if strcmpi(param.csarp.sar_type,'fk')
      % fk migration overview
      %
      % 1. Loop for each subaperture (repeat steps 2-4 for each aperture)
      %
      % 2. Motion compensation required before taking FFT
      %    g_data (raw with coherent noise optionally removed)
      %      --> g_data (motion compensated ft-fft)
      %
      % 3. Uniform re-sampling
      %   a. uniform_en = false, Assume data is uniformly sampled, apply fft in slow time and
      %      decimate in this domain by dropping doppler bins outside window
      %      g_data (motion compensated ft-fft)
      %        --> g_data (slow time ft/st-fft) [only done on the first loop]
      %        --> data (decimated ft/st-fft)
      %   b. uniform_en = true, Spatial filter to decimated axis and then take fft
      %      g_data (motion compensated ft-fft)
      %        --> data (decimated ft-fft)
      %        --> data (decimated ft/st-fft)
      %
      % 4. Regular fk migration for each subaperture
      
      g_data{img_idx}(:,:,wf_adc_idx) = fft(g_data{img_idx}(:,:,wf_adc_idx),[],1);
      
      fcs.squint = [0 0 -1].';
      %fcs.squint = fcs.squint ./ sqrt(dot(fcs.squint,fcs.squint));
      
      %% Motion Compensation for fk migration
      if param.csarp.mocomp.en
        % Determine the required motion compensation (drange and dx)
        %  Positive drange means the the range will be made longer, time delay
        %  will be made larger, and phase will be more negative
        %  Positive dx means that the data will be shifted forward (i.e. it
        %  currently lags behind)
        fcs.type = param.csarp.mocomp.type;
        fcs.filter = param.csarp.mocomp.filter;
        [drange,dx] = sar_motion_comp(fcs,records,ref,along_track,output_along_track);
        
        % Time shift data in the frequency domain
        dtime = 2*drange/c;
        for rline = 1:size(g_data{img_idx},2)
          g_data{img_idx}(:,rline,wf_adc_idx) = g_data{img_idx}(:,rline,wf_adc_idx) ...
            .*exp(-1i*2*pi*wfs(wf).freq*dtime(rline));
        end
        
        along_track_mc = along_track + dx;
      else
        along_track_mc = along_track;
      end
      
      % output_along_track: these are the output values from csarp
      % output_along_track_pre/post: these are the buffers to keep the
      %   data from wrapping around in slow-time (i.e. linear convolution
      %   vs. circular convolution)
      % BUG!: At the beginning and end of a segment there is no data and
      % the buffer is not added... need to fix.
      output_along_track_pre = fliplr(output_along_track(1)-param.csarp.sigma_x:-param.csarp.sigma_x:along_track(1));
      if isempty(output_along_track_pre)
        output_along_track_pre = [output_along_track(1)-param.csarp.sigma_x*(param.load.start_zero_pad:-1:1), output_along_track_pre];
      else
        output_along_track_pre = [output_along_track_pre(1)-param.csarp.sigma_x*(param.load.start_zero_pad:-1:1), output_along_track_pre];
      end
      output_along_track_post = output_along_track(end)+param.csarp.sigma_x:param.csarp.sigma_x:along_track(end);
      if isempty(output_along_track_post)
        output_along_track_post = [output_along_track_post, output_along_track(end)+param.csarp.sigma_x*(1:param.load.stop_zero_pad)];
      else
        output_along_track_post = [output_along_track_post, output_along_track_post(end)+param.csarp.sigma_x*(1:param.load.stop_zero_pad)];
      end
      output_along_track_full = [output_along_track_pre output_along_track output_along_track_post];

      %% Prepare subaperture variables
      num_subapertures = length(param.csarp.sub_aperture_steering);
      if mod(num_subapertures,2) ~= 1
        error('Number of subapertures must be even');
      end
      if any(param.csarp.sub_aperture_steering ~= -(num_subapertures-1)/4 : 0.5 : (num_subapertures-1)/4)
        error('param.csarp.sub_aperture_steering must be of the form -N:0.5:N');
      end
      proc_oversample = (1+num_subapertures)/2; % Oversampling rate
      proc_sigma_x = param.csarp.sigma_x / proc_oversample;
      proc_along_track = output_along_track_full(1) ...
        + proc_sigma_x * (0:length(output_along_track_full)*proc_oversample-1);

      %% Uniform resampling and subaperture selection for fk migration
      if param.csarp.mocomp.uniform_en
        % Uniformly resample data in slow-time onto output along-track
        data = arbitrary_resample(g_data{img_idx}(:,:,wf_adc_idx), ...
          along_track_mc,proc_along_track, struct('filt_len', ...
          proc_sigma_x*16,'dx',proc_sigma_x,'method','sinc'));
        data = fft(data,[],2);
        
      else
        % Assume data is already uniformly sampled in slow-time
        % There are lots of approximations in this section... it's a bit
        % of a hack.
        x_lin = linspace(along_track(1), ...
          along_track(end),length(along_track));
        
        % Create kx (along-track wavenumber) axis of input data
        kx = gen_kx(x_lin);
        
        % Create kx axis of output (desired) data
        kx_desired = gen_kx(output_along_track_full);
        
        % Take slow-time FFT and decimate the data onto the desired
        % output along track positions by selecting just the doppler
        % bins that correspond to this

        g_data{img_idx}(:,:,wf_adc_idx) = fft(g_data{img_idx}(:,:,wf_adc_idx),[],2);
        filt_idx = kx < max(kx_desired) & kx > min(kx_desired);
        % Since kx and kx_desired won't match up perfectly, we may have
        % to append a few more doppler bins to get the numbers to line
        % up.
        if length(output_along_track_full) - sum(filt_idx) == 1
          filt_idx(find(filt_idx==0,1)) = 1;
        elseif length(output_along_track_full) - sum(filt_idx) == 2
          filt_idx(find(filt_idx==0,1)) = 1;
          filt_idx(find(filt_idx==0,1,'last')) = 1;
        end
        filt_len = length(find(filt_idx));
        filt_idx = filt_idx.';
        filt_idx = find(filt_idx);
        kx_sa    = kx(filt_idx);
        [kx_sa,kx_idxs] = sort(kx_sa);
        filt_idx = filt_idx(kx_idxs);
        filt_idx = ifftshift(filt_idx);
        data = g_data{img_idx}(:,filt_idx,wf_adc_idx);
      end
      
      %% fk migration
      if param.csarp.mocomp.en
        eps_r  = perm_profile(mean(records.surface + dtime),wfs(wf).time,'constant',param.csarp.start_eps);
      else
        eps_r  = perm_profile(mean(records.surface),wfs(wf).time,'constant',param.csarp.start_eps);
      end

      kx = gen_kx(proc_along_track);
      fk_data_ml = fk_migration(data,wfs(wf).time,wfs(wf).freq,kx,eps_r,param);
      fk_data_ml = fk_data_ml(:,1+length(output_along_track_pre):end-length(output_along_track_post),:);

      if 0
        % DEBUG code
        figure(1); clf;
        for subap = 1:num_subapertures
          imagesc(lp(fk_data_ml(300:700,:,subap)))
          title(sprintf('%d',subap ));
          pause(1);
        end
        figure(1); clf;
        imagesc(lp(mean(abs(fk_data_ml(300:700,:,:)).^2,3)));
        figure(2); clf;
        imagesc(lp(mean(abs(fk_data_ml(300:700,:,1:6)).^2,3)));
        figure(3); clf;
        imagesc(lp(mean(abs(fk_data_ml(300:700,:,end-5:end)).^2,3)));
      end
      
      if param.csarp.mocomp.en
        %% Undo motion compensation
        % Resample dtime to fk migration output
        dtime = interp1(orig_records.gps_time,dtime,fcs.gps_time);
        
        % Time shift data in the frequency domain
        fk_data_ml = fft(fk_data_ml,[],1);
        fk_data_ml = fk_data_ml.*exp(1i*2*pi*repmat(wfs(wf).freq, [1,size(fk_data_ml,2),size(fk_data_ml,3)]) ...
          .*repmat(dtime, [size(fk_data_ml,1),1,size(fk_data_ml,3)]));
        fk_data_ml = ifft(fk_data_ml,[],1);
      end
      
      %% Save Radar data
      for subap = 1:num_subapertures
        % Create output path
        out_fn_dir = fullfile(ct_filename_out(param, ...
          param.csarp.out_path), ...
          sprintf('%s_data_%03d_%02d_%02d',param.csarp.sar_type,param.load.frm, ...
          subap, param.load.sub_band_idx));
        if ~exist(out_fn_dir,'dir')
          mkdir(out_fn_dir);
        end
        
        % Save
        param_records = old_param_records;
        param_csarp = param;
        if param.csarp.combine_rx
          out_fn = fullfile(out_fn_dir,sprintf('img_%02d_chk_%03d.mat', img_idx, param.load.chunk_idx));
        else
          out_fn = fullfile(out_fn_dir,sprintf('wf_%02d_adc_%02d_chk_%03d.mat', wf, adc, param.load.chunk_idx));
        end
        fk_data = fk_data_ml(:,:,subap);
        fprintf('  Saving %s (%s)\n', out_fn, datestr(now));
        save('-v6',out_fn,'fk_data','fcs','lat','lon','elev','out_rlines','wfs','param_csarp','param_records');
      end
      
    elseif strcmpi(param.csarp.sar_type,'tdbp_old')
      % time domain backporjection overview
      data = g_data{img_idx}(:,:,wf_adc_idx);
      
      % set up SAR coordinate system
      [x_ecef, y_ecef, z_ecef] = geodetic2ecef(records.lat*pi/180, records.lon*pi/180, records.elev, WGS84.ellipsoid);
      records.lon_ref = mean(records.lon);
      records.lat_ref = mean(records.lat);
      records.elev_ref = mean(records.elev);
      [x_enu,y_enu,z_enu] = ecef2lv(x_ecef, y_ecef, z_ecef, records.lat_ref*pi/180, records.lon_ref*pi/180, records.elev_ref, WGS84.ellipsoid);
%       along_track =  [0 cumsum(sqrt(diff(x_enu).^2 + diff(y_enu).^2))];
      SAR_coord_param.phase_center = [x_enu;y_enu;z_enu];
      SAR_coord_param.Lsar = Lsar;
      SAR_coord_param.along_track = along_track;
      SAR_coord_param.output_along_track_idxs = param.proc.output_along_track_idxs;
%       if strcmpi(param.season_name,'mcords_simulator') % for 20110708_01_001 simulated data
%         param.proc.output_along_track_idxs = [fliplr([4632:-10:0]),[4642:10:length(along_track)]];
%         SAR_coord_param.output_along_track_idxs = param.proc.output_along_track_idxs;
%       end
      SAR_coord_param.wfs = wfs(wf);
      
      % surface tracker
      % two methods to get ice surface: param.surf_source 1/2
      % 1: from get_heights; 2:from laser data;
      param.surf_source = 1;
      if param.surf_source == 1
        surfTimes = records.surface;
      elseif param.surf_source == 2
        param.laser_surface = 1;
        param.laser_data_fn = '/cresis/projects/metadata/2008_Greenland_TO_icessn/2008_Greenland/080801a_icessn_nadir0seg';
        param.laser_data_fn = '/cresis/projects/metadata/2008_Greenland_TO_icessn/2008_Greenland/080707_icessn_nadir0seg';
        fid = fopen(param.laser_data_fn);
        [laser_data_tmp] = textscan(fid,'%f%f%f%f%f%f%f%f%f%f%f');
        fclose(fid);
        Year = 2008;
        Mon = 7;
        Day = 7;
        laser_data.gps_time = (datenum(Year,Mon,Day)-datenum(1970,1,1))*86400 + laser_data_tmp{1};
        laser_data.surf_elev = laser_data_tmp{4};
        laser_data.surf_elev = interp1(laser_data.gps_time,laser_data.surf_elev,records.gps_time);
        surfTimes = 2*(records.elev-laser_data.surf_elev)/c;
        clear laser_data_tmp;
      end
      
      SAR_coord_param.surf = zeros(3,length(along_track));
      SAR_coord_param.surf(1,:) = x_enu;
      SAR_coord_param.surf(2,:) = y_enu;
      SAR_coord_param.surf(3,:) = z_enu - surfTimes*c/2;
      SAR_coord_param.surf_p = polyfit(along_track,SAR_coord_param.surf(3,:),10);
      SAR_coord_param.surf(3,:) = polyval(SAR_coord_param.surf_p,along_track);
      N = length(SAR_coord_param.surf_p);
      surfSlope = SAR_coord_param.surf_p(N-1);
      x_pwr = along_track;
      for ii = N-3:-1:1
        surfSlope = surfSlope + (N-ii)*SAR_coord_param.surf_p(ii)*along_track.*x_pwr;
        x_pwr = x_pwr.*along_track;
      end
      surfSlope = surfSlope + 2*SAR_coord_param.surf_p(N-2)*along_track;
      surfSlope(abs(surfSlope)<0.0001*pi/180) = 0;
      SAR_coord_param.surfAngle = atan(surfSlope);
      % SAR_coord_param.surfNormal = zeros(3,length(along_track));
      % SAR_coord_param.surfNormal(1,:) = cos(atan(surfSlope)+pi/2);
      % SAR_coord_param.surfNormal(3,:) = sin(atan(surfSlope)+pi/2);
      % SAR_coord_param.surfNormalAngle = atan(surfSlope)+pi/2;
      SAR_coord_param.surfBins = round((2*(z_enu-SAR_coord_param.surf(3,:))/c-wfs(wf).time(1))/wfs(wf).dt) + 1;
      
      n = size(data,1);
      m = length(param.proc.output_along_track_idxs);
      SAR_coord_param.pixel = zeros(3,n,m);
      SAR_coord_param.pixel(1,:,:) = repmat(x_enu(param.proc.output_along_track_idxs),n,1);
      SAR_coord_param.pixel(2,:,:) = repmat(y_enu(param.proc.output_along_track_idxs),n,1);
      eta_ice = sqrt(er_ice);
      for line = 1:m
        out_idx = param.proc.output_along_track_idxs(line);
        SAR_coord_param.pixel(3,1:SAR_coord_param.surfBins(out_idx),line) = z_enu(out_idx) - wfs(wf).time(1)*c/2 - ...
          [(0:SAR_coord_param.surfBins(out_idx)-1)'*wfs(wf).dt*c/2];
        SAR_coord_param.pixel(3,SAR_coord_param.surfBins(out_idx)+1,line) = ...
          SAR_coord_param.pixel(3,SAR_coord_param.surfBins(out_idx),line) -...
          c*(surfTimes(out_idx)-wfs(wf).time(SAR_coord_param.surfBins(out_idx)))/2 -...
          (wfs(wf).time(SAR_coord_param.surfBins(out_idx)+1)-surfTimes(out_idx))*c/(2*eta_ice);
        SAR_coord_param.pixel(3,SAR_coord_param.surfBins(out_idx)+2:n,line) = ...
          SAR_coord_param.pixel(3,SAR_coord_param.surfBins(out_idx)+1,line) - ...
          (1:n-SAR_coord_param.surfBins(out_idx)-1)'*wfs(wf).dt*c/(2*eta_ice);
      end
      SAR_coord_param.h = SAR_coord_param.phase_center(3,:)-SAR_coord_param.surf(3,:);
      SAR_coord_param.h_mean = mean(SAR_coord_param.h);
      Lsar_surf = c/wfs(wf).fc*SAR_coord_param.h_mean/(2*param.csarp.sigma_x);
      SAR_coord_param.HbeamWidth = atan(0.5*Lsar_surf/SAR_coord_param.h_mean);
      
      tdbp_param = SAR_coord_param;
      clear SAR_coord_param;
      tdbp_param.proc.Nfft = 2^ceil(log2(length(wfs(wf).time_raw)));
      tdbp_param.proc.skip_surf = param.csarp.skip_surf;
      tdbp_param.proc.start_range_bin_above_surf = param.csarp.start_range_bin_above_surf;
      tdbp_param.proc.start_range_bin = param.csarp.start_range_bin;
      tdbp_param.proc.end_range_bin = param.csarp.end_range_bin;
      tdbp_param.refraction_method = param.csarp.refraction_method;
      tdbp_param.fc = wfs(wf).fc;
      tdbp_param.time = wfs(wf).time;
      tdbp_param.c = c;
      tdbp_param.eta_ice = eta_ice;
      tdbp_param.st_wind = param.csarp.st_wind;
      tdbp_param.sub_aperture_steering = param.csarp.sub_aperture_steering;
            
      fcs.squint = [0 0 -1].';
      tdbp_data0 = tdbp(tdbp_param,data);
      
      for subap = 1:size(tdbp_data0,3) % save each subaperture data to its own folder
        % Create output path
        out_path = fullfile(ct_filename_out(param,param.csarp.out_path, 'CSARP_out'),...
          sprintf('tdbp_data_%03d_%02d_%02d',param.proc.frm,subap, param.proc.sub_band_idx));
        if ~exist(out_path,'dir')
          mkdir(out_path);
        end
        
        % Create filename
        % - Hack: multiple receivers are named with the first receiver in the list
        out_fn = sprintf('wf_%02d_adc_%02d_chk_%03d', wf, adc, param.csarp.chunk_id);
        out_full_fn = fullfile(out_path,[out_fn '.mat']);
        
        % Save
        fprintf('  Saving output %s\n', out_full_fn);
        param_records = old_param_records;
        param_csarp = param;
        param_csarp.tdbp = tdbp_param;
        tdbp_data = tdbp_data0(:,:,subap);
        save('-v6',out_full_fn,'tdbp_data','fcs','lat','lon','elev','wfs','param_csarp','param_records','tdbp_param');
      end
    elseif strcmpi(param.csarp.sar_type,'mltdp')
      fcs.squint = [0 0 -1].';
      [B,A] = butter(4,0.1);

      % Force elevation to be smooth (might be required for refraction)
      smoothed_elevation = filtfilt(B,A,records.elev);
      smoothed_ref_elevation = filtfilt(B,A,ref.elev);

      % Fit surface to polynomial to force it to be smooth (required for refraction)
      %  - Fit is done with special x-axis to prevent bad conditioning
      smoothed_surface = filtfilt(B,A,records.surface);
      sz_poly_order = 11;
      xfit = linspace(-1,1,length(smoothed_surface));
      smoothed_surface = polyval(polyfit(xfit,smoothed_surface,sz_poly_order),xfit);
      if 0 % set to 1 for surface fit over whole frame
        smoothed_elevation = interp1(param.proc.along_track_frm,param.proc.smoothed_elevation,param.proc.along_track,'linear','extrap');
        smoothed_surface = interp1(param.proc.along_track_frm,param.proc.smoothed_surface,param.proc.along_track,'linear','extrap');
      end

      data = g_data{img_idx}(:,:,wf_adc_idx);        
      % options for processing window in fast time
      surfBins_at_output = round((smoothed_surface-wfs(wf).time(1))/wfs(wf).dt)+1;
      if isempty(param.csarp.skip_surf)
        param.scarp.skip_surf = 0;                   % default value
      end
      if isempty(param.csarp.start_range_bin_above_surf)
        param.csarp.start_range_bin_above_surf = 5;  % default value
      end
      if param.csarp.skip_surf
        if isempty(param.csarp.start_range_bin)
          param.csarp.start_range_bin = max(surfBins_at_output) + 5;   % default value
        end
      else
        param.csarp.start_range_bin = min(surfBins_at_output) - param.csarp.start_range_bin_above_surf;        % default value
      end
      if isempty(param.csarp.end_range_bin)
        param.csarp.end_range_bin = size(data,1);  % default value
      end
%       if strcmpi(param.season_name,'mcords_simulator') % for 20110708_01_001 simulated data
%         output_along_track(463) = along_track(4632);
%         output_along_track(1:462) = output_along_track(463)-[462:-1:1]*param.csarp.sigma_x;
%         output_along_track(464:925) = output_along_track(463)+[1:462]*param.csarp.sigma_x;
%       end
      mltdp_data0 = ml_tdp(data,wfs(wf).fc,wfs(wf).time,along_track, smoothed_ref_elevation, ...
        smoothed_elevation,smoothed_surface,output_along_track,Lsar, ...
        length(param.csarp.sub_aperture_steering),param.csarp.start_range_bin,param.csarp.end_range_bin,param.csarp.start_eps);
      
      for subap = 1:size(mltdp_data0,3) % save each subaperture data to its own folder
        % Create output path
        out_path = fullfile(ct_filename_out(param,param.csarp.out_path, 'CSARP_out'),...
          sprintf('mltdp_data_%03d_%02d_%02d',param.proc.frm,subap, param.proc.sub_band_idx));
        if ~exist(out_path,'dir')
          mkdir(out_path);
        end
        
        % Create filename
        % - Hack: multiple receivers are named with the first receiver in the list
        out_fn = sprintf('wf_%02d_adc_%02d_chk_%03d',wf, adc,param.csarp.chunk_id);
        out_full_fn = fullfile(out_path,[out_fn '.mat']);
        
        fprintf('  Saving output %s\n', out_full_fn);
        param_records = old_param_records;
        param_csarp = param;
        mltdp_data = mltdp_data0(:,:,subap);
        save('-v6',out_full_fn,'mltdp_data','fcs','lat','lon','elev','wfs','param_csarp','param_records');
      end
    elseif strcmpi(param.csarp.sar_type,'tdbp')
    %% Time Domain Processor
      % time domain backporjection overview
      data = g_data{img_idx}(:,:,wf_adc_idx);
      
%       fcs_phase_centers = SAR_coord_system(SAR_coord_param,records,ref,along_track,along_track);
      fcs_phase_center_idxs = interp1(output_along_track,1:length(output_along_track),along_track,'nearest');
      if isnan(fcs_phase_center_idxs(1))
        fcs_phase_center_idxs(1:find(~isnan(fcs_phase_center_idxs),1)-1) = 1;
      end
      if isnan(fcs_phase_center_idxs(end))
        fcs_phase_center_idxs(find(~isnan(fcs_phase_center_idxs),1,'last')+1:end) = length(output_along_track);
      end
      for fcs_idx = 1:length(fcs_phase_center_idxs)
        fcs_phase_centers.x(:,fcs_idx) = fcs.x(:,fcs_phase_center_idxs(fcs_idx));
      end
      
      records.lon_ref = mean(records.lon);
      records.lat_ref = mean(records.lat);
      records.elev_ref = mean(records.elev);
      
      % set up SAR coordinate system
      [x_ecef, y_ecef, z_ecef] = geodetic2ecef(records.lat*pi/180, records.lon*pi/180, records.elev, WGS84.ellipsoid);

      SAR_coord_param.phase_center = [x_ecef;y_ecef;z_ecef];
      SAR_coord_param.Lsar = sar.Lsar;
      a1 = along_track(1);
      SAR_coord_param.along_track = along_track-a1;
      % Should be in c++ indices.
      SAR_coord_param.output_along_track = output_along_track-a1;
      SAR_coord_param.output_pos = fcs.origin;
      SAR_coord_param.wfs = wfs(wf);
      
      % surface tracker
      % two methods to get ice surface: param.surf_source 1/2
      % 1: from get_heights; 2:from laser data;
      param.surf_source = 1;
      if param.surf_source == 1
        surfTimes = records.surface;
      elseif param.surf_source == 2
        param.laser_surface = 1;
        param.laser_data_fn = '/cresis/projects/metadata/2008_Greenland_TO_icessn/2008_Greenland/080801a_icessn_nadir0seg';
        param.laser_data_fn = '/cresis/projects/metadata/2008_Greenland_TO_icessn/2008_Greenland/080707_icessn_nadir0seg';
        fid = fopen(param.laser_data_fn);
        [laser_data_tmp] = textscan(fid,'%f%f%f%f%f%f%f%f%f%f%f');
        fclose(fid);
        Year = 2008;
        Mon = 7;
        Day = 7;
        laser_data.gps_time = (datenum(Year,Mon,Day)-datenum(1970,1,1))*86400 + laser_data_tmp{1};
        laser_data.surf_elev = laser_data_tmp{4};
        laser_data.surf_elev = interp1(laser_data.gps_time,laser_data.surf_elev,records.gps_time);
        surfTimes = 2*(records.elev-laser_data.surf_elev)/c;
        clear laser_data_tmp;
      end
      
      for i = 1:3
        fcs_phase_centers.x(i,:) = interp1(output_along_track,fcs.x(i,:),along_track);
        fcs_phase_centers.z(i,:) = interp1(output_along_track,fcs.z(i,:),along_track);
      end
      idx1 = find(~isnan(fcs_phase_centers.x(1,:)),1)-1;
      idx2 = find(~isnan(fcs_phase_centers.x(1,:)),1,'last')+1;
      for i = 1:3
        fcs_phase_centers.x(i,1:idx1) = fcs_phase_centers.x(i,idx1+1);
        fcs_phase_centers.x(i,idx2:end) = fcs_phase_centers.x(i,idx2-1);
        fcs_phase_centers.z(i,1:idx1) = fcs_phase_centers.z(i,idx1+1);
        fcs_phase_centers.z(i,idx2:end) = fcs_phase_centers.z(i,idx2-1);
      end
      
%       SAR_coord_param.surf = zeros(3,length(along_track));
%       SAR_coord_param.surf(1,:) = x_ecef +surfTimes*c/2 .* fcs_phase_centers.z(1,:);
%       SAR_coord_param.surf(2,:) = y_ecef + surfTimes*c/2 .* fcs_phase_centers.z(2,:);
%       SAR_coord_param.surf(3,:) = z_ecef + surfTimes*c/2 .* fcs_phase_centers.z(3,:);
      
      surfTimes = sgolayfilt(records.surface,3,round(param.csarp.surf_filt_dist / median(diff(along_track))/2)*2+1);
%       surfTimes = sar.surf_pp.coefs(out_rlines,end);
%       SAR_coord_param.surf_poly = sar.surf_pp.coefs(out_rlines,:).'*c/2;
      SAR_coord_param.surf_along_track = -surfTimes*c/2;
      surf_poly = spline(along_track,SAR_coord_param.surf_along_track);
      SAR_coord_param.surf_poly = surf_poly.coefs.';
      SAR_coord_param.surf_line = polyfit(along_track,SAR_coord_param.surf_along_track,1);
      
      [~,surf_max_idx] = max(SAR_coord_param.surf_along_track);
      if surf_max_idx==length(SAR_coord_param.surf_along_track);
        surf_max_idx = surf_max_idx-1;
      elseif surf_max_idx==1;
        surf_max_idx = 2;
      end
      surf_max_poly = SAR_coord_param.surf_poly(:,surf_max_idx);
      surf_der = polyval([length(surf_max_poly)-1:-1:1].'.*surf_max_poly(1:end-1),0);
      if surf_der==0
        surf_max = surf_max_poly(end);
      elseif surf_der<0
        surf_max_idx = surf_max_idx-1;
        surf_max_poly = SAR_coord_param.surf_poly(:,surf_max_idx);
      end
      surf_at_max = roots((length(surf_max_poly)-1:-1:1).'.*surf_max_poly(1:end-1));
     	surf_at_max = surf_at_max(surf_at_max>0 & surf_at_max<diff(along_track(surf_max_idx+[0,1])));
      if isempty(surf_at_max)
        surf_max = max(SAR_coord_param.surf_along_track(surf_max_idx+[0,1]));
      else
        surf_max = max(polyval(surf_max_poly,surf_at_max));
      end
      
      SAR_coord_param.surf_max = surf_max;
      
      x_ecef = fcs.origin(1,:);
      y_ecef = fcs.origin(2,:);
      z_ecef = fcs.origin(3,:);
            
      SAR_coord_param.surfBins = floor((surfTimes - wfs(wf).time(1))/wfs(wf).dt);
      
      jordan; % filter these
      output_surfTimes = -fcs.surface;
      output_surfBins = floor((fcs.surface - wfs(wf).time(1))/wfs(wf).dt);
      
      t0 = wfs(wf).time(1);
            
      n = size(data,1);
      m = length(output_along_track);
      SAR_coord_param.pixel = zeros(3,n,m);
      eta_ice = sqrt(er_ice);
      for line = 1:m
        surfBin = output_surfBins(line);
        surfTime = abs(output_surfTimes(line));
        
        % if surface data is collected by radar
        if surfBin<n
%           
          pixel_ranges = wfs(wf).time(1:surfBin)*c/2;
          SAR_coord_param.pixel(1,1:surfBin,line) = x_ecef(line) + ...
            pixel_ranges*fcs_phase_centers.z(1,line);
          SAR_coord_param.pixel(2,1:surfBin,line) = y_ecef(line) + ...
            pixel_ranges*fcs_phase_centers.z(2,line);
          SAR_coord_param.pixel(3,1:surfBin,line) = z_ecef(line) + ...
            pixel_ranges*fcs_phase_centers.z(3,line);
          
          pixel_ranges = (surfTime + (wfs(wf).time(surfBin+1)-surfTime)/eta_ice) * c/2;
          SAR_coord_param.pixel(1,surfBin+1,line) = x_ecef(line) + ...
            pixel_ranges*fcs_phase_centers.z(1,line);
          SAR_coord_param.pixel(2,surfBin+1,line) = y_ecef(line) + ...
            pixel_ranges*fcs_phase_centers.z(2,line);
          SAR_coord_param.pixel(3,surfBin+1,line) = z_ecef(line) + ...
            pixel_ranges*fcs_phase_centers.z(3,line);
          
          if surfBin<n-1
            pixel_ranges = pixel_ranges+(wfs(wf).time(surfBin+2:end)-wfs(wf).time(surfBin+1))*c/eta_ice/2;
            SAR_coord_param.pixel(1,surfBin+2:end,line) = x_ecef(line) + ...
              pixel_ranges*fcs_phase_centers.z(1,line);
            SAR_coord_param.pixel(2,surfBin+2:end,line) = y_ecef(line) + ...
              pixel_ranges*fcs_phase_centers.z(2,line);
            SAR_coord_param.pixel(3,surfBin+2:end,line) = z_ecef(line) + ...
              pixel_ranges*fcs_phase_centers.z(3,line);
          end
          
        % if surface data is not collected by radar
        else
          
          pixel_ranges = wfs(wf).time(1:surfBin)*c/2;
          SAR_coord_param.pixel(1,:,line) = x_ecef(line) + ...
            pixel_ranges*fcs_phase_centers.z(1,line);
          SAR_coord_param.pixel(2,:,line) = y_ecef(line) + ...
            pixel_ranges*fcs_phase_centers.z(2,line);
          SAR_coord_param.pixel(3,:,line) = z_ecef(line) + ...
            pixel_ranges*fcs_phase_centers.z(3,line);
          
        end
      end
      
      if isfield(param.csarp,'end_time') && ~isempty(param.csarp.end_time)
        if param.csarp.end_time<=wfs(wf).time(end) && param.csarp.end_time>=wfs(wf).time(1)
          tdbp_param.end_time = param.csarp.end_time;
          t_idx = interp1(wfs(wf).time,1:length(wfs(wf).time),param.csarp.end_time,'next');
          SAR_coord_param.pixel = SAR_coord_param.pixel(:,1:t_idx,:);
        end
      end
%       
      if isfield(param.csarp,'start_time') && ~isempty(param.csarp.start_time)
        if param.csarp.start_time<=wfs(wf).time(end) && param.csarp.start_time>=wfs(wf).time(1)
          tdbp_param.start_time = param.csarp.start_time;
          t_idx = interp1(wfs(wf).time,1:length(wfs(wf).time),param.csarp.start_time,'previous');
          SAR_coord_param.pixel = SAR_coord_param.pixel(:,t_idx:end,:);
        end
      end
            
      % number of entries in library
      N_lib = 32;

      dt = wfs(wf).dt;

      bw = wfs(wf).f1 - wfs(wf).f0;
      
      % sub-time bin step given number of entries
      dts = dt/N_lib;

      matched_sig_lib = zeros(wfs(wf).Nt,N_lib);
      mid = ceil(wfs(wf).Nt/2+1);
      % loop through delays and directly create matched signal response
      %   implements marginal time shift in signal to find envelope.
      t = ((1:size(matched_sig_lib,1)).'-mid)*dt;
      for del_idx = 0:(N_lib-1)
          matched_sig_lib(:,del_idx+1) = sinc((t-dts*del_idx)*bw);
      end
      % Filter contains ~97.5% of area under sinc^2 curve
      matched_sig_lib = matched_sig_lib(mid+(-ceil(3.94/bw/dt):ceil(3.94/bw/dt)),:);
      
      tdbp_param = SAR_coord_param;
      clear SAR_coord_param;
            
      tdbp_param.fc = wfs(wf).fc;
      tdbp_param.t0 = t0;
      tdbp_param.dt = dt;
      tdbp_param.matched_sig_lib = matched_sig_lib;
      
      tdbp_param.fcs_x = fcs_phase_centers.x;
      
      tdbp_param.st_wind = param.csarp.st_wind;
      tdbp_param.k_window = 1;
      
      tdbp_param.n0 = 1;
      tdbp_param.n1 = eta_ice;
      
      if isfield(param.csarp,'refraction_flag');
        tdbp_param.refraction_flag = param.csarp.refraction_flag;
      end
      
      kx_bw = abs(c/wfs(wf).fc)/param.csarp.sigma_x;
      
      num_subapertures = length(param.csarp.sub_aperture_steering);
      tdbp_data0 = [];
      for subap = 1:num_subapertures
      
        kx0 = param.csarp.sub_aperture_steering(subap);
        kx_support_limits = asin(kx0+kx_bw*[-1,1]/2);
        
        tdbp_param.kx_support_limits = kx_support_limits;
        
        fprintf('Beginning SAR Processing...\n');
        tdbp_data0(:,:,subap) = sar_proc_task(tdbp_param,double(data));
      end
      
      for subap = 1:size(tdbp_data0,3) % save each subaperture data to its own folder
        % Create output path
        out_path = fullfile(ct_filename_out(param,param.csarp.out_path, 'CSARP_out'),...
          sprintf('tdbp_data_%03d_%02d_%02d',param.load.frm,subap, param.load.sub_band_idx));
        if ~exist(out_path,'dir')
          mkdir(out_path);
        end
        
        % Create filename
        % - Hack: multiple receivers are named with the first receiver in the list
        out_fn = sprintf('wf_%02d_adc_%02d_chk_%03d', wf, adc, param.load.chunk_idx);
        out_full_fn = fullfile(out_path,[out_fn '.mat']);
        
        % Save
        fprintf('  Saving output %s\n', out_full_fn);
        param_records = old_param_records;
        param_csarp = param;
        param_csarp.tdbp = tdbp_param;
        tdbp_data = tdbp_data0(:,:,subap);
        save('-v7.3',out_full_fn,'tdbp_data','fcs','lat','lon','elev','wfs','param_csarp','param_records','tdbp_param');
      end
    end
  end
end

fprintf('%s done %s\n', mfilename, datestr(now));

success = true;

return
