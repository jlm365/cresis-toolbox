function plot_echogram(obj,x_min,x_max,y_min,y_max)
% echowin.plot_echogram(obj,x_min,x_max,y_min,y_max)
%
% Plot echogram data from echogram files

physical_constants;
% ======================================================================
%% Convert the data along the x-axis according to the units
xaxis_choice = get(obj.left_panel.xaxisPM,'Value');
if xaxis_choice == 1 % rangeline
  % update image_xaxis and image_gps_time
  obj.eg.image_xaxis = 1:length(obj.eg.gps_time);
  obj.eg.image_gps_time = obj.eg.gps_time;
  % update image_data according to xaxis_gpstime
  obj.eg.image_data = obj.eg.data;
  % update x label
  obj.eg.x_label = 'Range Line';
  
elseif xaxis_choice == 2 % Along track
  along_track = geodetic_to_along_track(obj.eg.lat, obj.eg.lon, obj.eg.elev);
  % Set along track sampling, estimate best along-track pixel size, dx, from the data
  dx = median(diff(along_track));
  along_track_uniform = along_track(1): dx :along_track(end);
  % update image_xaxis and image_gps_time
  obj.eg.image_xaxis = along_track_uniform/1000;
  obj.eg.image_gps_time = interp1(along_track,obj.eg.gps_time,...
    along_track_uniform,'linear');
  % update image_data according to image_gps_time
  obj.eg.image_data = interp1(obj.eg.gps_time,...
    obj.eg.data.',obj.eg.image_gps_time,'linear').';
  % update x label
  obj.eg.x_label = 'Along track (km)';
  
elseif xaxis_choice == 3 % GPS time
  tmp_gpstime = obj.eg.gps_time;
  % Set gps time sampling, estimate best gps time pixel size, dg, from the data
  dg = median(diff(tmp_gpstime));
  gps_time_uniform = tmp_gpstime(1):dg:tmp_gpstime(end);
  % update image_xaxis and image_gps_time
  obj.eg.image_gps_time = gps_time_uniform;
  obj.eg.image_xaxis = gps_time_uniform;
  % update display_data according to xaxis_gpstime
  obj.eg.image_data = interp1(obj.eg.gps_time,...
    obj.eg.data.',obj.eg.image_gps_time,'linear').';
  % update x label
  obj.eg.x_label = 'GPS time';
end

% Create the image_* variables for faster interpolation of cursor
obj.eg.image_lat = interp1(obj.eg.gps_time,obj.eg.lat,obj.eg.image_gps_time,'linear');
obj.eg.image_lon = interp1(obj.eg.gps_time,obj.eg.lon,obj.eg.image_gps_time,'linear');
obj.eg.image_elev = interp1(obj.eg.gps_time,obj.eg.elev,obj.eg.image_gps_time,'linear');
obj.eg.image_surf_twtt = interp1(obj.eg.gps_time,obj.eg.surf_twtt,obj.eg.image_gps_time,'linear');

obj.eg.image_ecef = zeros(3,length(obj.eg.image_gps_time));
[obj.eg.image_ecef(1,:),obj.eg.image_ecef(2,:),obj.eg.image_ecef(3,:)] ...
  = geodetic2ecef(obj.eg.image_lat/180*pi,obj.eg.image_lon/180*pi,obj.eg.image_elev,WGS84.ellipsoid);
[z_vec_x,z_vec_y,z_vec_z] = geodetic2ecef(obj.eg.image_lat/180*pi,obj.eg.image_lon/180*pi,obj.eg.image_elev-1,WGS84.ellipsoid);

obj.eg.image_y_vec = zeros(3,length(obj.eg.image_gps_time));
obj.eg.image_z_vec = zeros(3,length(obj.eg.image_gps_time));
Nx = size(obj.eg.image_ecef,2);
for rline = 1:Nx
  % Construct x-vector (points along-track)
  start_rline = max(1,rline-10);
  stop_rline = min(Nx,rline+10);
  x_vec = obj.eg.image_ecef(:,stop_rline) - obj.eg.image_ecef(:,start_rline);
  % Construct z-vector (points up)
  obj.eg.image_z_vec(:,rline) = [obj.eg.image_ecef(1,rline)-z_vec_x(rline); obj.eg.image_ecef(2,rline)-z_vec_y(rline); obj.eg.image_ecef(3,rline)-z_vec_z(rline)];
  % Construct y-vector (points left)
  obj.eg.image_y_vec(:,rline) = cross(x_vec,obj.eg.image_z_vec(:,rline));
  % Normalize vectors
  obj.eg.image_y_vec(:,rline) = obj.eg.image_y_vec(:,rline) ...
    ./ sqrt(dot(obj.eg.image_y_vec(:,rline),obj.eg.image_y_vec(:,rline)));
  obj.eg.image_z_vec(:,rline) = obj.eg.image_z_vec(:,rline) ...
    ./ sqrt(dot(obj.eg.image_z_vec(:,rline),obj.eg.image_z_vec(:,rline)));
end

% ======================================================================
%% Convert the data along the y-axis according to the units
% perform y-axis conversion (from twtt)
yaxis_choice = get(obj.left_panel.yaxisPM,'Value');
vel_air = c/2;
vel_ice = c/(sqrt(er_ice)*2);
if yaxis_choice == 1 % TWTT
  % update yaxis and yaxis_time
  obj.eg.image_yaxis = obj.eg.time*1e6;
  % update y label
  obj.eg.y_label = 'Two-way Propagation (\mus)';
  obj.eg.y_order = 'reverse';
  
elseif yaxis_choice == 2 % WGS_84 Elevation
  elevation = interp1(obj.eg.gps_time,...
    obj.eg.elev,obj.eg.image_gps_time,'linear');
  time = obj.eg.time;
  surface = interp1(obj.eg.gps_time,...
    obj.eg.surf_twtt,obj.eg.image_gps_time,'linear');
  physical_constants;
  elev_max = max(elevation - time(1)*vel_air);
  elev_min = min(elevation - surface*vel_air - (time(end)-surface)*vel_ice);
  dt = time(2) - time(1);
  drange = dt * vel_ice;
  elev_uniform = (elev_max:-drange:elev_min).';
  % update image_data
  Nt = size(obj.eg.image_data,1);
  obj.eg.image_data = [obj.eg.image_data;...
    zeros(length(elev_uniform)-Nt,size(obj.eg.image_data,2))];
  warning('off','MATLAB:interp1:NaNinY')
  for idx = 1:length(surface)
    range = min(time,surface(idx)) * vel_air ...
      + max(0,time-surface(idx)) * vel_ice;
    elev = elevation(idx) - range;
    obj.eg.image_data(:,idx) = interp1(elev,...
      obj.eg.image_data(1:Nt,idx),elev_uniform,'linear');
  end
  warning('on','MATLAB:interp1:NaNinY')
  % update image_yaxis
  obj.eg.image_yaxis = elev_uniform;
  % update y label
  obj.eg.y_label = 'Elevation (m)';
  obj.eg.y_order = 'normal';
  
elseif yaxis_choice == 3 % Range
  time = obj.eg.time;
  surface = interp1(obj.eg.gps_time,...
    obj.eg.surf_twtt,obj.eg.image_gps_time,'linear');
  range_min = time(1)*vel_air;
  range_max = max(surface*vel_air + (time(end)-surface)*vel_ice);
  dt = time(2) - time(1);
  drange = dt * vel_ice;
  Nt = size(obj.eg.image_data,1);
  range_uniform = (range_min:drange:max(range_min+drange*(Nt-1),range_max)).';
  % update image_data
  obj.eg.image_data = [obj.eg.image_data;...
    zeros(length(range_uniform)-Nt,size(obj.eg.image_data,2))];
  for idx = 1:length(surface)
    range = min(time,surface(idx)) * vel_air ...
      + max(0,time-surface(idx)) * vel_ice;
    obj.eg.image_data(:,idx) = interp1(range,...
      obj.eg.image_data(1:Nt,idx),range_uniform,'linear');
  end
  % update image_yaxis
  obj.eg.image_yaxis = range_uniform;
  % update y label
  obj.eg.y_label = 'Range (m)';
  obj.eg.y_order = 'reverse';
  
elseif yaxis_choice == 4 % Range bin
  % update image_yaxis
  obj.eg.image_yaxis = 1:length(obj.eg.time);
  % update y label
  obj.eg.y_label = 'Range bin';
  obj.eg.y_order = 'reverse';
  
elseif yaxis_choice == 5 % Surface flat
  time = obj.eg.time;
  surface = interp1(obj.eg.gps_time,...
    obj.eg.surf_twtt,obj.eg.image_gps_time,'linear');
  % surface is always positive (or else we are flying inside the ice
  % medium), but start time may be after the surface
  %   
  depth_min = min(min(0,time(1)-surface) * vel_air ...
    + max(0,time(1)-surface) * vel_ice);
  
  depth_max = max(min(0,time(end)-surface) * vel_air ...
    + max(0,time(end)-surface) * vel_ice);
  
  dt = time(2) - time(1); % time step size
  d_depth = dt * c/(sqrt(er_ice)*2); % depth step size that we will interpolate onto
  depth_uniform = (depth_min:d_depth:depth_max).'; % depth axis we will interpolate onto
  % update image_data
  Nt = size(obj.eg.image_data,1);
  obj.eg.image_data = [obj.eg.image_data;...
    zeros(length(depth_uniform)-Nt,size(obj.eg.image_data,2))];
  for idx = 1:length(surface)
    depth = min(0,time-surface(idx)) * vel_air ...
      + max(0,time-surface(idx)) * vel_ice;
    obj.eg.image_data(:,idx) = interp1(depth,...
      obj.eg.image_data(1:Nt,idx),depth_uniform,'linear');
  end
  % update image_yaxis
  obj.eg.image_yaxis = depth_uniform;
  % update y label
  obj.eg.y_label = 'Depth (m)';
  obj.eg.y_order = 'reverse';
  
end

% ======================================================================
%% We plot the whole data matrix and then use xlim and ylim to control the
% limits of what is displayed
set(obj.h_image,'XData',obj.eg.image_xaxis,'YData',obj.eg.image_yaxis);
obj.left_panel.imagewin.set_cdata(obj.eg.image_data);
zoom reset;

%% Add labels, y-direction of axis, title, and set the colormap
xlabel(obj.h_axes,obj.eg.x_label);
ylabel(obj.h_axes,obj.eg.y_label);
set(obj.h_axes,'YDir',obj.eg.y_order);
title_str = sprintf('%s %d to %d',obj.eg.cur_sel.day_seg, ...
  obj.eg.frms(1), obj.eg.frms(end));
title(title_str,'Interpreter','none','Parent',obj.h_axes);

%% Set axis limits
%  -- Handle edge of segment case
dx = obj.eg.image_xaxis(2)-obj.eg.image_xaxis(1);
image_xaxis_min = obj.eg.image_xaxis(1);
image_xaxis_max = obj.eg.image_xaxis(end);
if obj.eg.frms(1) == 1
  % First frame in segment so adjust beginning to make sure all layer points
  % will be displayed.
  image_xaxis_min = interp1(obj.eg.image_gps_time,obj.eg.image_xaxis,obj.eg.start_gps_time(1),'linear','extrap')-dx;
elseif obj.eg.frms(end) == length(obj.eg.stop_gps_time)
  % Last frame of segment so adjust end to make sure all layer points will 
  % be displayed.
  image_xaxis_max = interp1(obj.eg.image_gps_time,obj.eg.image_xaxis,obj.eg.stop_gps_time(end),'linear','extrap')+dx;
end
x_lims = interp1(obj.eg.image_gps_time,obj.eg.image_xaxis,[x_min x_max],'linear','extrap');
x_lim_low = max([min(x_lims) image_xaxis_min]);
x_lim_high = min([max(x_lims) image_xaxis_max]);
xlim(obj.h_axes,[x_lim_low,x_lim_high]);
if y_min == -inf
  y_min = min(obj.eg.image_yaxis([1 end]));
end
if y_max == inf
  y_max = max(obj.eg.image_yaxis([1 end]));
end
ylim(obj.h_axes,sort([y_min y_max]))

%% Apply the display mode
obj.left_panel.imagewin.set_cdata(obj.eg.image_data);

end
