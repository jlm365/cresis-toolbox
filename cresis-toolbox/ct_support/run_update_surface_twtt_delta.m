% script run_update_surface_twtt_delta
%
% Runs update_surface_twtt_delta.m
%
% Author: John Paden

%% User Settings
% ----------------------------------------------------------------------
% params = read_param_xls(ct_filename_param('kuband_param_2014_Greenland_P3.xls'));
% params = read_param_xls(ct_filename_param('rds_param_2015_Greenland_Polar6.xls'));
% params = read_param_xls(ct_filename_param('snow_param_2009_Greenland_P3.xls'));
% params = read_param_xls(ct_filename_param('snow_param_2010_Greenland_DC8.xls'));
params = read_param_xls(ct_filename_param('snow_param_2010_Greenland_P3.xls'));
% params = read_param_xls(ct_filename_param('snow_param_2011_Greenland_P3.xls'));
% params = read_param_xls(ct_filename_param('snow_param_2012_Greenland_P3.xls'));
data_types = {'qlook'};
imgs = [0];

%% Automated Section
% ----------------------------------------------------------------------

update_surface_twtt_delta;

return;
